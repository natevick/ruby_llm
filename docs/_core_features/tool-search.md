---
layout: default
title: Tool Search
nav_order: 9
description: Keep large tool catalogs out of the model's context. Mark tools as deferred and let a provider's tool-search mechanism load only the ones a conversation needs.
redirect_from:
  - /guides/tool-search
---

# {{ page.title }}
{: .no_toc }

{{ page.description }}
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

After reading this guide, you will know:

*   When deferred tool loading helps.
*   How to mark tools as deferred.
*   Which providers support it and what happens on the others.
*   How to observe which tools the model loaded.

## When to use it

When a `RubyLLM::Chat` is wired to many tools — especially across one or more
MCP servers — every tool's full JSON Schema ships on every request. Three real
costs follow:

1. **Token bloat.** Hundreds of tools can add tens of thousands of tokens per
   request.
2. **Prompt-cache eviction.** Adding or removing tools changes the request
   prefix and invalidates the cache.
3. **Selection accuracy.** Models choose worse tools when the menu is long.

Tool search fixes all three: you mark tools as **deferred**, and the provider
keeps their schemas out of the model's context until its tool-search mechanism
loads the ones the conversation actually needs. This is a RubyLLM-level feature
with a small per-provider adapter underneath; the API below is the same
whichever provider you use.

## Provider support

| Provider | Protocol | Deferred loading |
|----------|----------|------------------|
| Anthropic | `:anthropic` | Native — server-side BM25 tool search (Sonnet/Haiku 4.5, Opus 4.5+, Fable/Mythos 5; Opus 4.1 and earlier are unsupported) |
| OpenAI | `:responses` (default) | Native — the `tool_search` tool (gpt-5.4 and later) |
| OpenAI | `:chat_completions` | Not supported |
| Everyone else (Gemini, Bedrock/Converse, Mistral, …) | — | Not supported |

Support is checked per **model**, not just per provider (via each provider's
capabilities), and it's resolved on **every request** — so switching models
mid-chat (including automatic fallbacks) transparently activates or degrades
deferral. When the current protocol/model can't do tool search, the deferred
tools are sent eagerly with a one-time warning — the same code runs
everywhere.

Two Anthropic constraints are handled for you: the native search tool is always
sent non-deferred (so you never hit the "all tools deferred" 400 even when every
one of *your* tools is deferred), and combining `defer:` with a tool's
`cache_control` raises a clear error rather than a 400.

## Marking tools as deferred

### Per-class DSL

```ruby
class DeepResearchTool < RubyLLM::Tool
  description "Runs a multi-step web investigation"
  deferred  # class-level default

  parameter :query, description: "..."
  def execute(query:); ...; end
end
```

### Per-call, for bulk registration (the MCP case)

```ruby
chat = RubyLLM.chat(model: "claude-sonnet-4-6")
chat.with_tools(*mcp_client.tools, defer: true)
```

Per-call `defer: true` overrides a non-deferred class; `defer: false` overrides
a `deferred` class.

## How the model loads deferred tools

Deferred tools go into `chat.tool_catalog` instead of the active `chat.tools`,
and they stay there: every request sends the same tools array — each deferred
tool with the provider's defer flag, plus that provider's tool-search
primitive. Because the array never changes between turns, the provider's
prompt cache is preserved (the point of the feature).

When the model searches and discovers a tool, the provider reports it back and
replays the search exchange in the conversation history on later requests, so
the model keeps using discovered tools without re-searching. RubyLLM executes
a discovered tool's calls exactly like an active tool's.

## Observing what was discovered

```ruby
chat.after_tool_search do |names|
  Rails.logger.info("tool_search discovered: #{names}")  # e.g. [:weather_lookup]
end

chat.tool_catalog                  # => #<RubyLLM::ToolCatalog deferred=42 loaded=3>
chat.tool_catalog.deferred_tools   # Hash of deferred tool name => Tool
chat.tool_catalog.loaded_tools     # Set of discovered tool-name Symbols
```

## Rails persistence

The search exchange rides the message's `raw_content` (the same mechanism
that replays server tools such as web search), so with the 2.0 schema it is
persisted and restored with the conversation and discovered tools stay
discovered across process restarts. It is replayed only while the request
still declares deferred tools; otherwise the search blocks are dropped and
the model re-searches. An optional `tool_references` JSON column on the
message model records which deferred tools each response discovered.

## Further reading

*   [Anthropic tool search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)
*   [OpenAI tool search](https://developers.openai.com/api/docs/guides/tools-tool-search)
*   [Tools guide]({% link _core_features/tools.md %})
