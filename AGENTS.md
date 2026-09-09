# AGENTS.md — Agentic

## Project

Elixir library (~> 1.19) providing a composable AI agent runtime. Mix project, no umbrella.

## Commands

```bash
mix deps.get                  # install deps (includes a GitHub-sourced recollect)
mix format                    # format all code
mix test                      # runs ecto.create + ecto.migrate + test (via alias)
mix setup                     # deps.get + ecto.setup (create + migrate)
mix ecto.reset                # drop + create + migrate
```

`mix test` is aliased to create and migrate the DB before running — but **no Ecto Repo module exists yet**, so the ecto steps are effectively no-ops. If a Repo is added later, the alias will activate automatically.

## Architecture

Entry point: `Agentic.run/1` (`lib/agentic.ex`). Accepts a prompt, workspace path, and a callbacks map (at minimum `:llm_chat`).

**Core loop** (`lib/agentic/loop/`):
- `Engine` builds a middleware-style pipeline from stage modules. Stages wrap each other right-to-left; each receives `ctx` and a `next` fun.
- `Profile` maps named profiles (`:agentic`, `:agentic_planned`, `:turn_by_turn`, `:conversational`) to stage lists and config.
- `Phase` is a pure-function state machine with per-mode validated phase transitions.
- `Context` is the loop state struct passed through every stage.

**Stage pipeline** (agentic profile, in order):
`ContextGuard → ProgressInjector → LLMCall → ModeRouter → ToolExecutor → CommitmentGate`

Additional profiles: `:agentic_planned` (plan → execute → verify), `:turn_by_turn` (human-in-the-loop review/execute), `:conversational` (call-respond only).

The loop does **not** use a step counter. `ModeRouter` decides loop/terminate/compact based on the `(mode, phase, stop_reason)` triple. `max_turns` is a safety rail only. Phase transitions are validated by `Agentic.Loop.Phase` — a pure-function state machine with per-mode transition maps.

**Other key directories**:
- `lib/agentic/tools/` — tool definitions and execution. Extension modules (`Skill`, `Gateway`, `Memory`) add non-file tools.
- `lib/agentic/storage/` — pluggable storage backends. `Storage.Context` delegates to a backend module; only `:local` (filesystem) exists.
- `lib/agentic/persistence/` — persistence behaviours (`Transcript`, `Plan`, `Knowledge`) with `:local` file-based backends.
- `lib/agentic/memory/` — context keeper (Registry-backed), fact extraction, commitment detection.
- `lib/agentic/skill/` — skill parsing and core skill definitions.
- `lib/agentic/workspace/` — workspace scaffolding and path validation.
- `priv/core_skills/` and `priv/prompts/` — bundled skill and prompt templates.

## Conventions

- **Tool schemas use string keys** everywhere (not atoms). Messages, content blocks, and LLM response maps are all string-keyed.
- **CircuitBreaker** (`lib/agentic/circuit_breaker.ex`) uses a bare ETS table, no GenServer. Inited in `Application.start/2`.
- **Application** (`lib/agentic/application.ex`) starts a `Registry` for `ContextKeeper` and calls `CircuitBreaker.init/0`.
- Test support code lives in `test/support/`, included via `elixirc_paths(:test)` in `mix.exs`.

## Testing

Tests use `Agentic.TestHelpers` (`test/support/test_helpers.ex`):
- `mock_callbacks/1` — returns a callbacks map with default mock LLM and tool responses; pass overrides to customize.
- `build_ctx/1` — creates a minimal `Context` with sensible defaults and activates tools.
- `create_test_workspace/0` — creates a temp dir and cleans up via `on_exit`.

Run a single test file:
```bash
mix test test/agentic/loop/engine_test.exs
```

Run a single test by line:
```bash
mix test test/agentic/loop/engine_test.exs:42
```

## Versioning

This library is consumed as a git dependency by Worth. When adding new functionality or making breaking changes, you **must** create a new git tag so that Worth's `mix.exs` can pin to a specific version. Follow semantic versioning.

### Release SOP

1. **Bump `version`** in `mix.exs` (line 7).
2. **Update deps** if needed — verify `mix deps.get` resolves cleanly.
3. **Run checks**: `mix format`, `mix test` — verify everything passes.
4. **Commit** the version bump with message `v{VERSION}`.
5. **Tag** the commit: `git tag v{VERSION}`. The tag name must match `mix.exs` exactly (prefixed with `v`).
6. **Push**: `git push origin main --tags`.

### Version History

| Version | Git Tag | Notes |
|---------|---------|-------|
| 0.3.1   | `v0.3.1` | Fix protocol registry ordering, optional callbacks, real-CLI opencode protocol |
| 0.2.1   | `v0.2.1` | Docs cleanup, bug fixes, recollect 0.5 bump |
| 0.2.0   | `v0.2.0` | Multi-mode loop, strategies, subagents, protocols, model router |
| 0.1.9   | `v0.1.9` | LLM gateway proxy, ACP streaming, codex profile |
