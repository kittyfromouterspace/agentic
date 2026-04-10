# AGENTS.md — AgentEx

## Project

Elixir library (~> 1.19) providing a composable AI agent runtime. Mix project, no umbrella.

## Commands

```bash
mix deps.get                  # install deps (includes a GitHub-sourced mneme)
mix format                    # format all code
mix test                      # runs ecto.create + ecto.migrate + test (via alias)
mix setup                     # deps.get + ecto.setup (create + migrate)
mix ecto.reset                # drop + create + migrate
```

`mix test` is aliased to create and migrate the DB before running — but **no Ecto Repo module exists yet**, so the ecto steps are effectively no-ops. If a Repo is added later, the alias will activate automatically.

## Architecture

Entry point: `AgentEx.run/1` (`lib/agent_ex.ex`). Accepts a prompt, workspace path, and a callbacks map (at minimum `:llm_chat`).

**Core loop** (`lib/agent_ex/loop/`):
- `Engine` builds a middleware-style pipeline from stage modules. Stages wrap each other right-to-left; each receives `ctx` and a `next` fun.
- `Profile` maps named profiles (`:agentic`, `:agentic_planned`, `:turn_by_turn`, `:conversational`) to stage lists and config.
- `Phase` is a pure-function state machine with per-mode validated phase transitions.
- `Context` is the loop state struct passed through every stage.

**Stage pipeline** (agentic profile, in order):
`ContextGuard → ProgressInjector → LLMCall → ModeRouter → ToolExecutor → CommitmentGate`

Additional profiles: `:agentic_planned` (plan → execute → verify), `:turn_by_turn` (human-in-the-loop review/execute), `:conversational` (call-respond only).

The loop does **not** use a step counter. `ModeRouter` decides loop/terminate/compact based on the `(mode, phase, stop_reason)` triple. `max_turns` is a safety rail only. Phase transitions are validated by `AgentEx.Loop.Phase` — a pure-function state machine with per-mode transition maps.

**Other key directories**:
- `lib/agent_ex/tools/` — tool definitions and execution. Extension modules (`Skill`, `Gateway`, `Memory`) add non-file tools.
- `lib/agent_ex/storage/` — pluggable storage backends. `Storage.Context` delegates to a backend module; only `:local` (filesystem) exists.
- `lib/agent_ex/persistence/` — persistence behaviours (`Transcript`, `Plan`, `Knowledge`) with `:local` file-based backends.
- `lib/agent_ex/memory/` — context keeper (Registry-backed), fact extraction, commitment detection.
- `lib/agent_ex/skill/` — skill parsing and core skill definitions.
- `lib/agent_ex/workspace/` — workspace scaffolding and path validation.
- `priv/core_skills/` and `priv/prompts/` — bundled skill and prompt templates.

## Conventions

- **Tool schemas use string keys** everywhere (not atoms). Messages, content blocks, and LLM response maps are all string-keyed.
- **CircuitBreaker** (`lib/agent_ex/circuit_breaker.ex`) uses a bare ETS table, no GenServer. Inited in `Application.start/2`.
- **Application** (`lib/agent_ex/application.ex`) starts a `Registry` for `ContextKeeper` and calls `CircuitBreaker.init/0`.
- Test support code lives in `test/support/`, included via `elixirc_paths(:test)` in `mix.exs`.

## Testing

Tests use `AgentEx.TestHelpers` (`test/support/test_helpers.ex`):
- `mock_callbacks/1` — returns a callbacks map with default mock LLM and tool responses; pass overrides to customize.
- `build_ctx/1` — creates a minimal `Context` with sensible defaults and activates tools.
- `create_test_workspace/0` — creates a temp dir and cleans up via `on_exit`.

Run a single test file:
```bash
mix test test/agent_ex/loop/engine_test.exs
```

Run a single test by line:
```bash
mix test test/agent_ex/loop/engine_test.exs:42
```

## Versioning

This library is consumed as a git dependency by Worth. When adding new functionality or making breaking changes, you **must** create a new git tag (e.g., `v0.3.0`) so that Worth's `mix.exs` can pin to a specific version. Follow semantic versioning.
