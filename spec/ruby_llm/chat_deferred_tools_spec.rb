# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Chat do
  include_context 'with configured RubyLLM'

  def define_tools!
    stub_const('RegularTool', Class.new(RubyLLM::Tool) { description 'plain tool' })
    stub_const('HeavyTool', Class.new(RubyLLM::Tool) do
      description 'heavy deferred tool'
      deferred
      def execute = 'heavy ran'
    end)
    stub_const('OtherTool', Class.new(RubyLLM::Tool) { description 'another tool' })
  end

  before { define_tools! }

  def anthropic_chat
    described_class.new(model: 'claude-haiku-4-5', provider: :anthropic, assume_model_exists: true)
  end

  def old_anthropic_chat
    described_class.new(model: 'claude-opus-4-1', provider: :anthropic, assume_model_exists: true)
  end

  describe '#with_tools routing' do
    it 'keeps non-deferred tools on the active list' do
      chat = anthropic_chat.with_tools(RegularTool)
      expect(chat.tools.keys).to include(:regular)
      expect(chat.tool_catalog).to be_empty
    end

    it 'routes a deferred class into the catalog, not the active tools' do
      chat = anthropic_chat.with_tools(HeavyTool)
      expect(chat.tool_catalog.deferred_tools.keys).to eq([:heavy])
      expect(chat.tools).to be_empty
    end

    it 'per-call defer: true overrides a non-deferred class' do
      chat = anthropic_chat.with_tools(OtherTool, defer: true)
      expect(chat.tool_catalog.deferred_tools.keys).to eq([:other])
    end

    it 'per-call defer: false overrides a deferred class' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: false)
      expect(chat.tools.keys).to include(:heavy)
      expect(chat.tool_catalog).to be_empty
    end

    it 'treats a truthy defer: as true' do
      chat = anthropic_chat.with_tools(OtherTool, defer: 1)
      expect(chat.tool_catalog.deferred_tools.keys).to eq([:other])
    end

    it 'routes a mixed batch by effective defer value' do
      chat = anthropic_chat.with_tools(RegularTool, HeavyTool, OtherTool, defer: true)
      expect(chat.tool_catalog.deferred_tools.keys).to match_array(%i[regular heavy other])
      expect(chat.tools).to be_empty
    end

    it 'records defer intent even on a provider without tool search (resolved at render)' do
      chat = described_class.new(model: 'gpt-5.4', provider: :openai, protocol: :chat_completions,
                                 assume_model_exists: true)
      chat.with_tools(HeavyTool, defer: true)
      expect(chat.tool_catalog.deferred_tools.keys).to eq([:heavy])
    end
  end

  describe 'same-name registrations keep one canonical entry' do
    it 'an active registration supersedes a prior deferred one' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true).with_tools(HeavyTool, defer: false)
      expect(chat.tools.keys).to eq([:heavy])
      expect(chat.tool_catalog).to be_empty
    end

    it 'a deferred registration supersedes a prior active one' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: false).with_tools(HeavyTool, defer: true)
      expect(chat.tools).to be_empty
      expect(chat.tool_catalog.deferred_tools.keys).to eq([:heavy])
    end

    it 're-deferring a discovered name starts a fresh lifecycle (tool stays sendable)' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      chat.tool_catalog.mark_loaded(:heavy)

      chat.with_tools(HeavyTool, defer: true)

      expect(chat.tool_catalog.deferred_tools.keys).to eq([:heavy])
      expect(chat.tool_catalog.loaded_tools).to be_empty
      expect(chat.send(:effective_tools).keys).to include(:heavy)
    end
  end

  describe 'duck-typed tools without a deferred? method' do
    it 'registers normally when defer is not requested (no NoMethodError)' do
      duck = Object.new
      def duck.name = 'duck'

      expect { anthropic_chat.with_tools(duck) }.not_to raise_error
    end
  end

  describe '#with_tools(nil)' do
    it 'clears both active tools and the deferred catalog' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true).with_tools(RegularTool)
      chat.with_tools(nil)
      expect(chat.tools).to be_empty
      expect(chat.tool_catalog).to be_empty
    end
  end

  describe '#effective_tools (render-time resolution)' do
    it 'returns the active tools unchanged when nothing is deferred' do
      chat = anthropic_chat.with_tools(RegularTool)
      expect(chat.send(:effective_tools)).to eq(chat.tools)
    end

    it 'wraps every catalog tool in a deferred Registration on a supporting model' do
      chat = anthropic_chat.with_tools(RegularTool).with_tools(HeavyTool, defer: true)
      effective = chat.send(:effective_tools)

      expect(effective.keys).to match_array(%i[regular heavy])
      expect(effective[:heavy]).to be_a(RubyLLM::Tool::Registration)
      expect(effective[:heavy].deferred?).to be(true)
      expect(effective[:regular]).not_to be_a(RubyLLM::Tool::Registration)
    end

    it 'keeps discovered tools deferred, so the tools array is identical across turns' do
      chat = anthropic_chat.with_tools(HeavyTool, OtherTool, defer: true)
      before_discovery = chat.send(:effective_tools)
      chat.tool_catalog.mark_loaded(:heavy)
      after_discovery = chat.send(:effective_tools)

      expect(after_discovery.keys).to eq(before_discovery.keys)
      expect(after_discovery[:heavy]).to be_a(RubyLLM::Tool::Registration)
      expect(after_discovery[:heavy].deferred?).to be(true)
    end

    it 'degrades catalog tools to eager (bare, with a one-time warning) on an unsupporting model' do
      allow(RubyLLM.logger).to receive(:warn)
      chat = old_anthropic_chat.with_tools(HeavyTool, OtherTool, defer: true)

      effective = chat.send(:effective_tools)
      chat.send(:effective_tools) # second render: warning must not repeat

      expect(effective.keys).to match_array(%i[heavy other])
      expect(effective.values).to all(be_a(RubyLLM::Tool))
      expect(RubyLLM.logger).to have_received(:warn).with(/does not support deferred/i).once
    end

    it 'follows the current model across #with_model switches, both directions' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      expect(chat.send(:effective_tools)[:heavy]).to be_a(RubyLLM::Tool::Registration)

      allow(RubyLLM.logger).to receive(:warn)
      chat.with_model('claude-opus-4-1', provider: :anthropic, assume_model_exists: true)
      expect(chat.send(:effective_tools)[:heavy]).not_to be_a(RubyLLM::Tool::Registration)

      chat.with_model('claude-haiku-4-5', provider: :anthropic, assume_model_exists: true)
      expect(chat.send(:effective_tools)[:heavy]).to be_a(RubyLLM::Tool::Registration)
    end
  end

  describe 'tool_choice on deferred tools' do
    it 'accepts a deferred tool as a named choice (the API expands forced deferred tools)' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      expect { chat.with_tool_options(choice: :heavy) }.not_to raise_error
      expect(chat.tool_prefs[:choice]).to eq(:heavy)
    end

    it 'accepts it on a provider where deferral degrades to eager registration' do
      chat = described_class.new(model: 'gpt-5.4', provider: :openai, protocol: :chat_completions,
                                 assume_model_exists: true)
      chat.with_tools(HeavyTool, defer: true)
      expect { chat.with_tool_options(choice: :heavy) }.not_to raise_error
    end

    it 'still rejects unknown tool names' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      expect { chat.with_tool_options(choice: :missing) }.to raise_error(RubyLLM::InvalidToolChoiceError)
    end
  end

  describe 'dispatch of discovered tools' do
    it 'executes a deferred tool the model calls, without any active registration' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      tool_call = RubyLLM::ToolCall.new(id: 't1', name: 'heavy', arguments: {})

      expect(chat.send(:execute_tool, tool_call)).to eq('heavy ran')
      expect(chat.tools).to be_empty
    end

    it 'reports catalog tools in the unavailable-tool error' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      tool_call = RubyLLM::ToolCall.new(id: 't1', name: 'missing', arguments: {})

      expect(chat.send(:execute_tool, tool_call)[:error]).to include('heavy')
    end
  end

  describe '#record_tool_search (private)' do
    it 'records discoveries and fires after_tool_search with the new names' do
      chat = anthropic_chat.with_tools(HeavyTool, OtherTool, defer: true)
      events = []
      chat.after_tool_search { |names| events << names }

      message = RubyLLM::Message.new(role: :assistant, content: '', tool_references: %w[heavy])
      chat.send(:record_tool_search, message)

      expect(chat.tool_catalog.loaded_tools).to include(:heavy)
      expect(chat.tools).to be_empty
      expect(events).to eq([[:heavy]])
    end

    it 'is a no-op with no references or an empty catalog' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      message = RubyLLM::Message.new(role: :assistant, content: 'plain', tool_references: [])
      expect { chat.send(:record_tool_search, message) }
        .not_to(change { chat.tool_catalog.loaded_tools.dup })

      bare = anthropic_chat.with_tools(RegularTool)
      referencing = RubyLLM::Message.new(role: :assistant, content: '', tool_references: %w[regular])
      expect { bare.send(:record_tool_search, referencing) }.not_to(change { bare.tools.keys })
    end

    it 'de-duplicates repeated references, firing after_tool_search only once' do
      chat = anthropic_chat.with_tools(HeavyTool, defer: true)
      events = []
      chat.after_tool_search { |names| events << names }

      chat.send(:record_tool_search,
                RubyLLM::Message.new(role: :assistant, content: '', tool_references: %w[heavy heavy]))
      chat.send(:record_tool_search,
                RubyLLM::Message.new(role: :assistant, content: '', tool_references: %w[heavy]))

      expect(events).to eq([[:heavy]])
    end
  end
end
