# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::ToolCatalog do
  def build_tool(const_name, desc)
    stub_const(const_name, Class.new(RubyLLM::Tool) { description(desc) })
    Object.const_get(const_name).new
  end

  let(:foo) { build_tool('FooTool', 'finds foo things') }
  let(:bar) { build_tool('BarTool', 'finds bar things') }

  describe '#empty? / #any?' do
    it 'starts empty' do
      expect(described_class.new).to be_empty
      expect(described_class.new.any?).to be(false)
    end

    it 'reports non-empty after add' do
      catalog = described_class.new.add(foo)
      expect(catalog).not_to be_empty
      expect(catalog.any?).to be(true)
    end
  end

  describe '#add' do
    it 'keys tools by their snake_case name and returns self' do
      catalog = described_class.new
      expect(catalog.add(foo)).to be(catalog)
      expect(catalog.deferred_tools.keys).to eq([:foo])
    end

    it 'overwrites on duplicate name' do
      stub_const('FooTool', Class.new(RubyLLM::Tool) { description('v1') })
      first = FooTool.new
      stub_const('FooTool', Class.new(RubyLLM::Tool) { description('v2') })
      second = FooTool.new

      catalog = described_class.new.add(first).add(second)
      expect(catalog.deferred_tools.size).to eq(1)
      expect(catalog.deferred_tools[:foo].description).to eq('v2')
    end

    it 'starts a fresh lifecycle: re-adding a discovered name clears its loaded marker' do
      catalog = described_class.new.add(foo)
      catalog.mark_loaded(:foo)

      catalog.add(foo)

      expect(catalog.loaded_tools).to be_empty
      expect(catalog.mark_loaded(:foo)).to eq(foo)
    end
  end

  describe '#remove' do
    it 'drops the tool from both deferred and loaded state' do
      catalog = described_class.new.add(foo).add(bar)
      catalog.mark_loaded(:foo)
      catalog.remove(:foo)

      expect(catalog.deferred_tools.keys).to eq([:bar])
      expect(catalog.loaded_tools).to be_empty
      expect(catalog.remove(:missing)).to be(catalog)
    end
  end

  describe '#[]' do
    it 'looks up a tool by name, tolerating strings' do
      catalog = described_class.new.add(foo)
      expect(catalog[:foo]).to eq(foo)
      expect(catalog['foo']).to eq(foo)
      expect(catalog[:missing]).to be_nil
    end
  end

  describe '#mark_loaded' do
    it 'records the discovery and returns the tool' do
      catalog = described_class.new.add(foo).add(bar)
      expect(catalog.mark_loaded(:foo)).to eq(foo)
      expect(catalog.loaded_tools).to contain_exactly(:foo)
    end

    it 'accepts string names' do
      catalog = described_class.new.add(foo)
      expect(catalog.mark_loaded('foo')).to eq(foo)
      expect(catalog.loaded_tools).to include(:foo)
    end

    it 'returns nil for unknown names and does not record them' do
      catalog = described_class.new.add(foo)
      expect(catalog.mark_loaded(:missing)).to be_nil
      expect(catalog.loaded_tools).to be_empty
    end

    it 'is idempotent: returns nil on a second discovery of the same tool' do
      catalog = described_class.new.add(foo)
      expect(catalog.mark_loaded(:foo)).to eq(foo)
      expect(catalog.mark_loaded(:foo)).to be_nil
      expect(catalog.loaded_tools).to contain_exactly(:foo)
    end
  end

  describe '#inspect' do
    it 'reports counts' do
      catalog = described_class.new.add(foo).add(bar)
      catalog.mark_loaded(:foo)
      expect(catalog.inspect).to eq('#<RubyLLM::ToolCatalog deferred=2 loaded=1>')
    end
  end
end
