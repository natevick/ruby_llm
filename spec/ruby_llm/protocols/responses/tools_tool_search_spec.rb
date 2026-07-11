# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Protocols::Responses::Tools do
  def tool(name, deferred:)
    base = instance_double(RubyLLM::Tool, name: name, description: "#{name} desc",
                                          parameters_schema: { 'type' => 'object' },
                                          declared_parameters: {}, provider_options: {})
    deferred ? RubyLLM::Tool::Registration.new(base, deferred: true) : base
  end

  describe '.tool_for' do
    it 'omits defer_loading for a bare tool' do
      expect(described_class.tool_for(tool('a', deferred: false))).not_to have_key(:defer_loading)
    end

    it 'emits defer_loading: true for a deferred Registration' do
      expect(described_class.tool_for(tool('a', deferred: true))[:defer_loading]).to be(true)
    end
  end

  describe '.format_tools' do
    it 'does not append the tool_search tool when nothing is deferred' do
      formatted = described_class.format_tools(a: tool('a', deferred: false))
      expect(formatted.map { |t| t[:type] }).not_to include('tool_search')
    end

    it 'appends the native tool_search tool once when any function is deferred' do
      formatted = described_class.format_tools(a: tool('a', deferred: false), b: tool('b', deferred: true))
      expect(formatted.last).to eq({ type: 'tool_search' })
      expect(formatted.count { |t| t[:type] == 'tool_search' }).to eq(1)
    end
  end

  describe 'Responses::Chat tool-search parsing' do
    let(:chat_protocol) { RubyLLM::Protocols::Responses::Chat }
    let(:output) do
      [
        { 'type' => 'tool_search_call', 'id' => 'ts_1' },
        { 'type' => 'tool_search_output', 'tools' => [{ 'name' => 'weather_lookup' }, { 'name' => 'stock_price' }] },
        { 'type' => 'function_call', 'call_id' => 'c1', 'name' => 'weather_lookup', 'arguments' => '{}' }
      ]
    end

    it 'pulls loaded tool names from tool_search_output items' do
      expect(chat_protocol.parse_tool_references(output)).to eq(%w[weather_lookup stock_price])
    end

    it 'returns [] when there are no tool-search items' do
      expect(chat_protocol.parse_tool_references([{ 'type' => 'message' }])).to eq([])
    end

    it 'surfaces the references and raw output on the parsed Message' do
      data = { 'output' => output, 'model' => 'gpt-5.4', 'status' => 'completed', 'usage' => {} }
      message = RubyLLM::Protocols::Responses.allocate.send(:parse_completion_body, data, raw: nil)
      expect(message.tool_references).to eq(%w[weather_lookup stock_price])
      expect(message.raw_content).to eq(output)
    end
  end

  describe 'function_call namespace round-trip (discovered tools carry one)' do
    let(:chat_protocol) { RubyLLM::Protocols::Responses::Chat }

    it 'parses the namespace from a function_call item and replays it' do
      output = [{ 'type' => 'function_call', 'call_id' => 'c1', 'name' => 'weather_lookup',
                  'arguments' => '{}', 'namespace' => 'functions' }]
      calls = chat_protocol.parse_function_calls(output)
      expect(calls['c1'].namespace).to eq('functions')

      items = chat_protocol.format_function_call_items(calls)
      expect(items.first[:namespace]).to eq('functions')
    end

    it 'omits the namespace key for ordinary calls' do
      calls = { 'c1' => RubyLLM::ToolCall.new(id: 'c1', name: 'plain', arguments: {}) }
      expect(chat_protocol.format_function_call_items(calls).first).not_to have_key(:namespace)
    end
  end

  describe 'history replay of tool-search items through raw_content' do
    let(:protocol) { RubyLLM::Protocols::Responses.allocate }
    let(:items) do
      [{ 'type' => 'tool_search_call', 'id' => 'ts_1' },
       { 'type' => 'tool_search_output', 'tools' => [{ 'name' => 'weather_lookup' }] },
       { 'type' => 'function_call', 'call_id' => 'c1', 'name' => 'weather_lookup', 'arguments' => '{}' }]
    end
    let(:message) do
      RubyLLM::Message.new(
        role: :assistant, content: nil, raw_content: items,
        tool_calls: { 'c1' => RubyLLM::ToolCall.new(id: 'c1', name: 'weather_lookup', arguments: {}) }
      )
    end

    it 'replays the items verbatim while the request still declares deferred tools' do
      types = protocol.send(:format_assistant_items, message).map { |i| i['type'] }
      expect(types).to eq(%w[tool_search_call tool_search_output function_call])
    end

    it 'omits the search items when the request no longer carries deferred tools' do
      types = protocol.send(:format_assistant_items, message, replay_search: false).map { |i| i['type'] }
      expect(types).to eq(%w[function_call])
    end
  end

  describe 'Providers::OpenAI::Capabilities.supports_tool_search?' do
    let(:caps) { RubyLLM::Providers::OpenAI::Capabilities }

    it 'requires gpt-5.4 or later, with a hard version boundary' do
      expect(caps.supports_tool_search?('gpt-5.4')).to be(true)
      expect(caps.supports_tool_search?('gpt-5.6')).to be(true)
      expect(caps.supports_tool_search?('gpt-5.4-2026-01-01')).to be(true)
      expect(caps.supports_tool_search?('gpt-4.1')).to be(false)
      expect(caps.supports_tool_search?('gpt-5')).to be(false)
      expect(caps.supports_tool_search?('gpt-5.4foo')).to be(false)
      expect(caps.supports_tool_search?('o3')).to be(false)
    end
  end

  describe 'end-to-end request payload via Chat#render' do
    include_context 'with configured RubyLLM'

    let(:chat) do
      RubyLLM::Chat.new(model: 'gpt-5.4', provider: :openai, assume_model_exists: true)
    end

    before do
      stub_const('WeatherLookupTool', Class.new(RubyLLM::Tool) do
        description 'Looks up the current weather for a city.'
        deferred
        parameter :city, description: 'City name'
        def execute(city:) = "weather in #{city}"
      end)
      stub_const('CurrentTimeTool', Class.new(RubyLLM::Tool) do
        description 'Returns the current time.'
        def execute = 'now'
      end)
    end

    it 'sends defer_loading on deferred tools and appends the tool_search tool' do
      chat.with_tools(WeatherLookupTool, CurrentTimeTool)
      chat.ask_later('hi')

      tools = chat.render[:tools]
      weather = tools.find { |t| t[:name] == 'weather_lookup' }
      current = tools.find { |t| t[:name] == 'current_time' }

      expect(weather[:defer_loading]).to be(true)
      expect(current).not_to have_key(:defer_loading)
      expect(tools.count { |t| t[:type] == 'tool_search' }).to eq(1)
    end
  end
end
