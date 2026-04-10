# AgentEx

[![Elixir Version](https://img.shields.io/badge/Elixir-~%201.19-blue.svg)](https://elixir-lang.org/)
[![License](https://img.shields.io/badge/License-BSD--3--Clause-green.svg)](LICENSE)
[![Package](https://img.shields.io/badge/Package-Hex.pm-orange.svg)](https://hex.pm/packages/agent_ex)

A composable AI agent runtime for Elixir. Provides a complete agent loop with skills, working memory, knowledge persistence, and tool use. Drop it into any Elixir project to get a fully functional AI agent.

## Features

- **Composable Pipeline** — Middleware-style stage pipeline lets you mix and match agent behaviors
- **Multiple Profiles** — Four built-in profiles: `agentic`, `agentic_planned`, `turn_by_turn`, `conversational`
- **Tool Execution** — Built-in file operations, glob, grep, and extensibility for custom tools
- **Skills System** — YAML-defined skills that extend agent capabilities at runtime
- **Working Memory** — Context keeper with fact extraction and commitment detection
- **Persistence** — Transcript, plan, and knowledge persistence with pluggable backends
- **Cost Controls** — Per-session cost limits and token usage tracking
- **Telemetry** — Full event instrumentation via Telemetry

## Installation

Add AgentEx to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agent_ex, "~> 0.1.0"}
  ]
end
```

### Database Backend

AgentEx uses Mneme for knowledge persistence. Mneme supports two database backends:

**Option A: libSQL (Recommended for new projects)**
Single-file SQLite with native vector support. Zero configuration.

```elixir
def deps do
  [
    {:agent_ex, "~> 0.1.0"},
    {:ecto_libsql, "~> 0.9"}
  ]
end
```

Configure Mneme:
```elixir
config :mneme,
  database_adapter: Mneme.DatabaseAdapter.LibSQL,
  repo: MyApp.Repo,
  embedding: [
    provider: Mneme.Embedding.OpenRouter,
    dimensions: 768
  ]
```

**Option B: PostgreSQL (For existing installations)**
Traditional server-based database with pgvector extension.

```elixir
def deps do
  [
    {:agent_ex, "~> 0.1.0"},
    {:postgrex, "~> 0.19"},
    {:pgvector, "~> 0.3"}
  ]
end
```

Configure Mneme:
```elixir
config :mneme,
  database_adapter: Mneme.DatabaseAdapter.Postgres,
  repo: MyApp.Repo,
  embedding: [
    provider: Mneme.Embedding.OpenRouter,
    dimensions: 1536
  ]
```

## Quick Start

```elixir
result = AgentEx.run(
  prompt: "Create a README.md file for my project",
  workspace: "/path/to/your/project",
  callbacks: %{
    llm_chat: fn params -> MyLLM.chat(params) end
  }
)

{:ok, %{text: response, cost: 0.05, tokens: 150, steps: 3}}
```

## Architecture

AgentEx uses a **stage pipeline** architecture. Each stage wraps the next, receiving the context and a `next` function to call downstream:

```
ContextGuard → ProgressInjector → LLMCall → ModeRouter → ToolExecutor → CommitmentGate
```

- **Engine** builds the pipeline from stage modules
- **Profile** maps named profiles to stage lists and configuration
- **Phase** is a pure-function state machine with validated transitions
- **Context** is the loop state passed through every stage

### Profiles

| Profile | Behavior |
|---------|----------|
| `:agentic` | Full pipeline with tool use, progress tracking, context management (default) |
| `:agentic_planned` | Two-phase: plan → execute with tracking and verification |
| `:turn_by_turn` | LLM proposes changes, human approves before execution |
| `:conversational` | Simple call-respond, no tools |

## Callbacks API

The `callbacks` map connects AgentEx to your LLM provider and external systems:

### Required

- `:llm_chat` — `(params) -> {:ok, response} | {:error, term}`

### Optional

- `:execute_tool` — custom tool handler (defaults to built-in tools)
- `:on_event` — `(event, ctx) -> :ok` for UI streaming
- `:on_response_facts` — `(ctx, text) -> :ok` for custom fact processing
- `:on_tool_facts` — `(ws_id, name, result, turn) -> :ok`
- `:on_persist_turn` — `(ctx, text) -> :ok`
- `:get_tool_schema` — `(name) -> {:ok, schema} | {:error, reason}`
- `:get_secret` — `(service, key) -> {:ok, value} | {:error, reason}`
- `:knowledge_search` — `(query, opts) -> {:ok, entries} | {:error, term}`
- `:knowledge_create` — `(params) -> {:ok, entry} | {:error, term}`
- `:knowledge_recent` — `(scope_id) -> {:ok, entries} | {:error, term}`
- `:search_tools` — `(query, opts) -> [result]`
- `:execute_external_tool` — `(name, args, ctx) -> {:ok, result} | {:error, reason}`

## Core Tools

AgentEx ships with built-in tools for file operations:

- `file_read` — Read file contents
- `file_write` — Write or overwrite files
- `file_edit` — Apply targeted edits using line ranges
- `glob` — Find files by pattern
- `grep` — Search file contents
- `bash` — Execute shell commands
- `task` — Delegate to sub-agents
- `memory` — Store and retrieve facts
- `skills_list` — List available skills
- `skills_apply` — Apply a skill to the workspace
- `gateway` — Query external services

Extend via the skills system or custom callbacks.

## Storage Backends

- **Transcript** — Session history with event streaming
- **Plan** — Structured task plans (for `:agentic_planned` mode)
- **Knowledge** — Persistent fact storage with search
- **Context** — Workspace context with pluggable backends

All backends have a `:local` file-based implementation.

## Configuration

```elixir
AgentEx.run(
  prompt: "...",
  workspace: "/path",
  callbacks: %{llm_chat: &my_llm/1},
  profile: :agentic,          # which profile to use
  mode: :agentic,            # shorthand for profile
  system_prompt: "...",      # custom system prompt
  history: [...],            # prior messages
  model_tier: :primary,      # which model tier to use
  cost_limit: 5.0,          # per-session cost limit in USD
  session_id: "agx-...",     # custom session ID
  user_id: "user-123",       # for API key resolution
  plan: %{...}               # pre-built plan (for agentic_planned)
)
```

## Development

```bash
mix deps.get          # Install dependencies
mix setup             # Setup database
mix test             # Run tests
mix format           # Format code
mix dialyzer         # Type check
```

## License

BSD-3-Clause — See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome. Please ensure tests pass and dialyzer is clean before submitting PRs.