# frozen_string_literal: true

module RubyLLM
  module Protocols
    class Responses
      # Tools methods of the OpenAI Responses API. Function definitions are
      # flat rather than nested under a `function` key.
      module Tools
        module_function

        # The native OpenAI tool-search tool, appended to the tools array
        # whenever any tool is deferred. See
        # https://developers.openai.com/api/docs/guides/tools-tool-search
        NATIVE_TOOL_SEARCH = { type: 'tool_search' }.freeze

        def tool_for(tool)
          definition = {
            type: 'function',
            name: tool.name,
            description: tool.description,
            parameters: ChatCompletions::Tools.parameters_schema_for(tool),
            strict: false
          }
          definition[:defer_loading] = true if deferred?(tool)

          return definition if tool.provider_options.empty?

          RubyLLM::Support::Utils.deep_merge(definition, tool.provider_options)
        end

        # Formats every tool for the request, appending the native tool-search
        # tool when any function is deferred so the model can load the
        # deferred ones on demand.
        def format_tools(tools)
          formatted = tools.map { |_, tool| tool_for(tool) }
          # dup: payload hashes must stay mutable for before_request hooks.
          formatted << NATIVE_TOOL_SEARCH.dup if formatted.any? { |entry| entry[:defer_loading] }
          formatted
        end

        # Only a Registration explicitly marked deferred emits the wire-level
        # flag; a bare Tool never does, regardless of its class default.
        def deferred?(tool)
          tool.is_a?(RubyLLM::Tool::Registration) && tool.deferred?
        end

        def build_tool_choice(tool_choice)
          case tool_choice
          when :auto, :none, :required
            tool_choice
          else
            {
              type: 'function',
              name: tool_choice
            }
          end
        end
      end
    end
  end
end
