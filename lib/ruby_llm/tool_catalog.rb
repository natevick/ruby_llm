# frozen_string_literal: true

require 'set'

module RubyLLM
  # Holds a Chat's deferred tools: the ones kept out of the model's visible
  # tool menu until a provider's tool-search mechanism loads the ones the
  # conversation actually needs. Chat routes tools registered with
  # <tt>defer:</tt> (or a +deferred+ class) here instead of into its active
  # tool set.
  #
  # Deferred tools stay in the catalog for the life of the chat — every
  # request renders them with the provider's defer flag so the tools array is
  # identical across turns, which is what preserves the provider's prompt
  # cache. #loaded_tools tracks which ones the model has discovered, for
  # observability (Chat#after_tool_search); it does not affect rendering or
  # dispatch.
  class ToolCatalog
    # The deferred tools, as a Hash of tool name Symbols to Tool instances.
    attr_reader :deferred_tools

    # The Set of tool name Symbols the model has discovered so far.
    attr_reader :loaded_tools

    def initialize
      @deferred_tools = {}
      @loaded_tools = Set.new
    end

    # Returns whether the catalog holds no deferred tools.
    def empty?
      @deferred_tools.empty?
    end

    # Returns whether the catalog holds any deferred tools.
    def any?
      !empty?
    end

    # Adds +tool+ to the catalog, keyed by its name. Re-adding a name starts a
    # fresh lifecycle: any earlier discovery of that name is forgotten.
    # Returns +self+.
    def add(tool)
      sym = tool.name.to_sym
      @loaded_tools.delete(sym)
      @deferred_tools[sym] = tool
      self
    end

    # Drops the tool named +name+ from the catalog entirely, including any
    # discovery state. Returns +self+.
    def remove(name)
      sym = name.to_sym
      @deferred_tools.delete(sym)
      @loaded_tools.delete(sym)
      self
    end

    # Returns the tool named +name+, or +nil+.
    def [](name)
      @deferred_tools[name.to_sym]
    end

    # Records that the model discovered the tool named +name+ and returns it.
    # Returns +nil+ when the catalog has no such tool, or when it was already
    # marked — so a repeated reference can't fire a duplicate search event.
    def mark_loaded(name)
      sym = name.to_sym
      return nil unless @deferred_tools.key?(sym)
      return nil if @loaded_tools.include?(sym)

      @loaded_tools << sym
      @deferred_tools[sym]
    end

    def inspect
      "#<#{self.class} deferred=#{@deferred_tools.size} loaded=#{@loaded_tools.size}>"
    end
  end
end
