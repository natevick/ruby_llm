# frozen_string_literal: true

require 'set'

module RubyLLM
  class Chat
    # The provider-agnostic half of tool search: routing registrations into
    # the deferred catalog, assembling the tool set sent to the provider, and
    # recording which deferred tools the model discovered. The wire-format
    # specifics — how a deferred tool and the search primitive are rendered,
    # and how discoveries are reported back — live in each protocol's
    # tool-search adapter. Chat owns the catalog; protocols own the
    # vocabulary.
    #
    # Deferral is an intent recorded at registration and resolved at render
    # time: #effective_tools checks the current provider/model on every
    # request, so switching models (including fallbacks) transparently
    # activates or degrades deferral without re-registering tools.
    module ToolSearch
      # Registers a callback that receives the newly discovered tool names
      # (an Array of Symbols) each time a provider's tool-search mechanism
      # discovers deferred tools. Returns +self+.
      #
      #   chat.after_tool_search { |names| logger.info "discovered #{names}" }
      #
      def after_tool_search(&)
        add_callback(:after_tool_search, &)
      end

      private

      # Registers one tool through #with_tools, routing it into the deferred
      # catalog or the active tool set. A registration supersedes any earlier
      # one of the same name, so a name lives in exactly one place.
      def register_tool(tool, defer:)
        tool_instance = tool.is_a?(Class) ? tool.new : tool
        name = tool_instance.name.to_sym
        if defer_tool?(tool_instance, defer)
          @tools.delete(name)
          @tool_catalog.add(tool_instance)
        else
          @tool_catalog.remove(name)
          @tools[name] = tool_instance
        end
      end

      # The defer intent: an explicit +defer:+ wins (truthy defers); otherwise
      # the tool's +deferred+ class default applies, for tools that declare one.
      def defer_tool?(tool, explicit)
        return explicit ? true : false unless explicit.nil?

        tool.respond_to?(:deferred?) && tool.deferred?
      end

      # The tools sent to the provider. Active tools go as-is. Deferred tools
      # are resolved against the CURRENT provider/model on every request:
      # when tool search is supported they are all wrapped in a deferred
      # Registration — discovered ones included, so the tools array is
      # identical across turns and the provider's prompt cache survives.
      # Otherwise they degrade to eager registration with a one-time warning.
      def effective_tools
        return @tools if @tool_catalog.empty?

        if @provider.supports_deferred_tools?(@model, protocol: @protocol)
          deferred = @tool_catalog.deferred_tools.transform_values do |tool|
            Tool::Registration.new(tool, deferred: true)
          end
          deferred.merge(@tools)
        else
          warn_deferred_ignored("#{@provider.slug} (#{@model&.id}) does not support deferred tool loading")
          @tool_catalog.deferred_tools.merge(@tools)
        end
      end

      def warn_deferred_ignored(reason)
        @deferred_warnings ||= Set.new
        return if @deferred_warnings.include?(reason)

        @deferred_warnings << reason
        RubyLLM.logger.warn("Deferring tools disabled — #{reason}; registering them eagerly")
      end

      # Looks up a tool for dispatch: active tools first, then the deferred
      # catalog. Catalog lookup is deliberately discovery-independent —
      # deferral is a context optimization, not an authorization boundary,
      # so a registered tool the model calls by name always executes.
      def find_tool(name)
        sym = name.to_sym
        @tools[sym] || @tool_catalog[sym]
      end

      def unavailable_tool_error(tool_call)
        {
          error: "Model tried to call unavailable tool `#{tool_call.name}`. " \
                 "Available tools: #{(@tools.keys + @tool_catalog.deferred_tools.keys).to_json}."
        }
      end

      # Records the deferred tools a provider's tool-search mechanism
      # discovered, reported on +message+ as tool_references, and fires the
      # after_tool_search callback with the newly discovered names.
      def record_tool_search(message)
        return if @tool_catalog.empty?

        names = Array(message.respond_to?(:tool_references) ? message.tool_references : nil).uniq
        return if names.empty?

        discovered = names.filter_map { |name| @tool_catalog.mark_loaded(name)&.name&.to_sym }
        run_callbacks(:after_tool_search, discovered) unless discovered.empty?
      end
    end
  end
end
