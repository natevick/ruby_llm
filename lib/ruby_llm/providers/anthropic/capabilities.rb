# frozen_string_literal: true

module RubyLLM
  module Providers
    class Anthropic
      # Feature capability gaps not represented in upstream model catalogs.
      module Capabilities
        TOOL_CAPABILITIES = %w[tool_choice parallel_tool_calls].freeze

        def self.augment(capabilities, **)
          return capabilities unless capabilities.include?('function_calling')

          capabilities | TOOL_CAPABILITIES
        end

        # Models that support the tool search tool (deferred tool loading):
        # version 4.5 and later of every current family. Matches the
        # model-compatibility table (and claude-sonnet-5, verified live —
        # the table lags new releases, so parse the version numerically
        # rather than allowlisting ids):
        # https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool#model-compatibility
        def self.supports_tool_search?(model_id)
          # The minor capture is bounded to two digits so a date-suffixed
          # major-only snapshot (claude-opus-4-20250514) isn't read as
          # minor 20250514.
          match = model_id.to_s.match(/\Aclaude-(?:fable|mythos|opus|sonnet|haiku)-(\d+)(?:-(\d{1,2}))?(?=-|\z)/)
          return false unless match

          major = match[1].to_i
          minor = match[2].to_i
          major >= 5 || (major == 4 && minor >= 5)
        end
      end
    end
  end
end
