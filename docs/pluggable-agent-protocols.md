# Pluggable Agent Protocol Infrastructure

## Overview

This document describes an extensible architecture for supporting multiple agent backends in AgentEx. The key insight is treating CLI-based agents (Claude Code, OpenCode, etc.) as **stateful agent wire protocols** — distinct from the stateless LLM transports used for API-based models.

## Motivation

Currently, AgentEx supports LLM-based agents via the `llm_chat` callback, which assumes a stateless request/response pattern. However, CLI-based agents like Claude Code and OpenCode operate differently:

- **Long-running sessions** with persistent state
- **Interactive protocol** with setup/teardown sequences  
- **Streaming JSON** over stdin/stdout
- **Session resumption** for multi-turn conversations

Instead of forcing these into the LLM transport model, we introduce a pluggable protocol layer.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          AgentEx.Run                                    │
│                    (entry point unchanged)                              │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        AgentEx.Profile                                  │
├─────────────────────────────────────────────────────────────────────────┤
│  :agentic        → Profile with LLM stages                             │
│  :claude_code   → Profile with CLI protocol stages                    │
│  :opencode      → Profile with CLI protocol stages                    │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     AgentEx.AgentProtocol                              │
│                    (Behaviour - contract)                              │
├─────────────────────────────────────────────────────────────────────────┤
│  Transport Type: :llm | :local_agent                                   │
│                                                                     │
│  Implementations:                                                    │
│    - AgentEx.Protocol.LLM (existing callbacks-based)               │
│    - AgentEx.Protocol.ClaudeCode                                     │
│    - AgentEx.Protocol.OpenCode                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    AgentEx.Protocol.Registry                           │
│              (discovers and manages backends)                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Core Abstractions

### Transport Type

A transport type categorizes how the agent communicates:

```elixir
defmodule AgentEx.Protocol do
  @type transport_type :: :llm | :local_agent
  
  @doc "Returns the transport type for this protocol"
  @callback transport_type() :: transport_type()
end
```

- **`:llm`** — Stateless LLM API calls (existing pattern)
- **`:local_agent`** — Stateful CLI-based local agent

### Agent Protocol Behaviour

```elixir
defmodule AgentEx.AgentProtocol do
  @moduledoc """
  Behaviour for agent communication protocols.
  
  Implement this for backends that communicate via different wire formats,
  session management, or execution models.
  """

  alias AgentEx.Loop.Context

  @type session_id :: binary()
  @type protocol_response :: %{
    content: String.t(),
    tool_calls: [map()],
    usage: %{input: non_neg_integer(), output: non_neg_integer()},
    stop_reason: String.t() | nil,
    metadata: map()
  }

  # --- Lifecycle ---

  @doc "Start a new agent session"
  @callback start(backend_config :: map(), context :: Context.t()) ::
    {:ok, session_id} | {:error, term()}

  @doc "Send messages and receive response"
  @callback send(session_id, messages :: [map()], context :: Context.t()) ::
    {:ok, protocol_response} | {:error, term()}

  @doc "Resume an existing session with new messages"
  @callback resume(session_id, messages :: [map()], context :: Context.t()) ::
    {:ok, protocol_response} | {:error, term()}

  @doc "Stop and cleanup a session"
  @callback stop(session_id) :: :ok | {:error, term()}

  # --- Protocol-specific ---

  @doc "Parse a streaming chunk into messages"
  @callback parse_stream(chunk :: binary()) ::
    {:message, map()} | :partial | :eof | {:error, term()}

  @doc "Format messages for the wire protocol"
  @callback format_messages(messages :: [map()], context :: Context.t()) ::
    iodata()

  @doc "Return the transport type"
  @callback transport_type() :: AgentEx.Protocol.transport_type()

  # --- Optional callbacks ---

  @doc "Get estimated cost for a response (optional)"
  @callback estimate_cost(protocol_response) :: float()
  def estimate_cost(_), do: 0.0
end
```

### CLI-Specific Protocol

For local agent protocols, we add a helper behaviour:

```elixir
defmodule AgentEx.AgentProtocol.CLI do
  @moduledoc """
  Behaviour for CLI-based local agent protocols.
  
  Extends AgentProtocol with CLI-specific lifecycle and configuration.
  """

  alias AgentEx.AgentProtocol

  @type cli_config :: %{
    required(:command) => String.t(),
    optional(:args) => [String.t()],
    optional(:env) => %{String.t() => String.t()},
    optional(:clear_env) => [String.t()],
    optional(:session_mode) => :always | :existing | :none,
    optional(:session_id_fields) => [String.t()],
    optional(:reliability) => map()
  }

  @doc "Build CLI-specific configuration from profile config"
  @callback build_config(profile_config :: map()) :: cli_config()

  @doc "Return the CLI binary name for this protocol"
  @callback cli_name() :: String.t()

  @doc "Check if CLI is available on the system"
  @callback available?() :: boolean()

  # Inherit all AgentProtocol callbacks
  defmacro __using__(opts) do
    quote do
      @behaviour AgentEx.AgentProtocol
      @behaviour unquote(__MODULE__)
    end
  end
end
```

## Protocol Registry

```elixir
defmodule AgentEx.Protocol.Registry do
  @moduledoc """
  Registry for agent protocol implementations.
  
  Provides lookup and discovery of available protocols.
  """

  use GenServer

  @name __MODULE__

  # --- API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Register a protocol under a name"
  def register(name, protocol_module) do
    GenServer.cast(@name, {:register, name, protocol_module})
  end

  @doc "Look up a protocol by name"
  def lookup(name) do
    GenServer.call(@name, {:lookup, name})
  end

  @doc "List all registered protocol names"
  def list do
    GenServer.call(@name, :list)
  end

  @doc "Get protocols by transport type"
  def for_transport(type) do
    GenServer.call(@name, {:for_transport, type})
  end
end
```

## Profile Integration

Profiles declare which protocol to use:

```elixir
defmodule AgentEx.Loop.Profile do
  @type profile_config :: %{
    name: atom(),
    protocol: atom(),
    transport_type: AgentEx.Protocol.transport_type(),
    stages: [module()],
    config: map()
  }

  def config(:claude_code) do
    %{
      name: :claude_code,
      protocol: :claude_code,
      transport_type: :local_agent,
      stages: [
        AgentEx.Loop.Stages.ContextGuard,
        AgentEx.Loop.Stages.ProgressInjector,
        AgentEx.Loop.Stages.CLIExecutor,      # replaces LLMCall
        AgentEx.Loop.Stages.ModeRouter,
        AgentEx.Loop.Stages.ToolExecutor,
        AgentEx.Loop.Stages.CommitmentGate
      ],
      config: %{
        max_turns: 50,
        session_cost_limit_usd: 5.0
      }
    }
  end

  def config(:opencode) do
    %{...}
  end

  def config(:agentic) do
    %{
      name: :agentic,
      protocol: :llm,
      transport_type: :llm,
      stages: [
        AgentEx.Loop.Stages.ContextGuard,
        AgentEx.Loop.Stages.ProgressInjector,
        AgentEx.Loop.Stages.LLMCall,          # LLM transport
        AgentEx.Loop.Stages.ModeRouter,
        AgentEx.Loop.Stages.ToolExecutor,
        AgentEx.Loop.Stages.CommitmentGate
      ],
      config: %{
        max_turns: 50,
        session_cost_limit_usd: 5.0
      }
    }
  end
end
```

## Stage: CLI Executor

The CLI executor stage replaces LLMCall for local agent protocols:

```elixir
defmodule AgentEx.Loop.Stages.CLIExecutor do
  @moduledoc """
  Executes agent prompts via CLI-based local agent protocol.
  
  Handles session lifecycle, streaming, and response parsing.
  """

  alias AgentEx.{Loop.Context, Protocol.Registry}

  @behaviour AgentEx.Loop.Stage

  @impl true
  def call(ctx, next) do
    protocol = resolve_protocol(ctx)
    
    # Ensure session is started
    ctx = ensure_session(ctx, protocol)
    
    # Send messages and get response
    case protocol.send(ctx.session_id, ctx.messages, ctx) do
      {:ok, response} ->
        ctx = update_context_with_response(ctx, response)
        next.(ctx)
        
      {:error, reason} ->
        {:error, {:cli_executor, reason}}
    end
  end

  defp resolve_protocol(ctx) do
    profile_config = AgentEx.Loop.Profile.config(ctx.profile)
    protocol_name = profile_config[:protocol] || :llm
    
    case Registry.lookup(protocol_name) do
      {:ok, module} -> module
      nil -> raise "Protocol #{protocol_name} not registered"
    end
  end

  defp ensure_session(ctx, protocol) do
    if ctx.session_id do
      ctx
    else
      {:ok, session_id} = protocol.start(backend_config(ctx), ctx)
      %{ctx | session_id: session_id}
    end
  end
end
```

## Context Updates

The context struct gains protocol-specific fields:

```elixir
defmodule AgentEx.Loop.Context do
  defstruct [
    # ... existing fields ...
    
    # Protocol-specific
    :session_id,
    :backend_config,
    :protocol_module,
    :transport_type
  ]
end
```

## Implementation Example: Claude Code

```elixir
defmodule AgentEx.Protocol.ClaudeCode do
  @moduledoc """
  Claude Code CLI protocol implementation.
  
  Communicates via `claude -p --output-format stream-json` subprocess.
  """

  use AgentEx.AgentProtocol.CLI

  @cli_name "claude"
  @default_args [
    "-p",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--permission-mode", "bypassPermissions"
  ]

  @impl true
  def transport_type, do: :local_agent

  @impl true
  def cli_name, do: @cli_name

  @impl true
  def available? do
    System.findExecutable(@cli_name) != nil
  end

  @impl true
  def build_config(profile_config) do
    %{
      command: @cli_name,
      args: @default_args ++ (profile_config[:extra_args] || []),
      env: profile_config[:env] || %{},
      session_mode: :always,
      session_id_fields: ["session_id"]
    }
  end

  @impl true
  def start(backend_config, ctx) do
    port = Port.open(
      {:spawn_executable, backend_config.command},
      [:stream, :binary, :exit_status, {:args, backend_config.args}]
    )
    
    session_id = UUID.uuid4()
    :persistent_term.put({__MODULE__, session_id}, %{port: port})
    
    {:ok, session_id}
  end

  @impl true
  def send(session_id, messages, ctx) do
    config = fetch_config(session_id)
    
    # Format messages for Claude Code protocol
    formatted = format_messages(messages, ctx)
    
    # Send via stdin and read streaming response
    Port.command(config.port, [formatted, "\n"])
    
    collect_response(session_id, "")
  end

  @impl true
  def parse_stream(chunk) do
    # Claude Code outputs JSON lines, potentially with partial messages
    chunk
    |> String.split("\n", trim: true)
    |> Enum.reduce({:partial, []}, fn line, {acc, acc_messages} ->
      case Jason.decode(line) do
        {:ok, %{"type" => "content_block_delta", "delta" => delta}} ->
          {:partial, [delta | acc_messages]}
          
        {:ok, %{"type" => "content_block_stop"}} ->
          {:message, %{content: Enum.reverse(acc_messages)}}
          
        {:ok, %{"type" => "error", "error" => error}} ->
          {:error, error}
          
        _ ->
          {acc, acc_messages}
      end
    end)
  end

  @impl true
  def format_messages(messages, _ctx) do
    # Convert to Claude Code's JSON input format
    messages
    |> Enum.map(fn %{"role" => role, "content" => content} ->
      %{"type" => "message", "role" => role, "content" => [%{"type" => "text", "text" => content}]}
    end)
    |> Jason.encode!()
  end

  @impl true
  def stop(session_id) do
    config = fetch_config(session_id)
    Port.close(config.port)
    :persistent_term.erase({__MODULE__, session_id})
    :ok
  end
end
```

## Registration

At application startup:

```elixir
defmodule AgentEx.Application do
  def start(_type, _args) do
    children = [
      AgentEx.Protocol.Registry,
      # ... other children ...
    ]
    
    # Register built-in protocols
    AgentEx.Protocol.Registry.register(:claude_code, AgentEx.Protocol.ClaudeCode)
    AgentEx.Protocol.Registry.register(:opencode, AgentEx.Protocol.OpenCode)
    AgentEx.Protocol.Registry.register(:llm, AgentEx.Protocol.LLM)
    
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Integration with Callbacks

The existing callback system remains, but gets protocol-aware:

```elixir
defmodule AgentEx.AgentExCallbacks do
  def build(opts) do
    # ... existing callbacks ...
    
    # Add protocol-specific callbacks
    on_protocol_start: fn session_id, protocol -> 
      # Track session start
    end,
    
    on_protocol_message: fn message, protocol ->
      # Stream protocol messages to UI
    end
  end
end
```

## Migration Path

1. **Phase 1**: Add protocol registry and behaviours (non-breaking) ✅ Done
2. **Phase 2**: Create CLI executor stage with fallback ✅ Done
3. **Phase 3**: Migrate profiles to declare protocols ✅ Done
4. **Phase 4**: Deprecate implicit LLM-only assumptions — Pending

## Implementation Notes

### Files Created

- `lib/agent_ex/protocol.ex` — Transport type definitions
- `lib/agent_ex/agent_protocol.ex` — Core protocol behaviour
- `lib/agent_ex/agent_protocol/cli.ex` — CLI-specific behaviour extensions
- `lib/agent_ex/protocol/registry.ex` — Protocol registry GenServer
- `lib/agent_ex/protocol/llm.ex` — LLM wrapper protocol
- `lib/agent_ex/protocol/claude_code.ex` — Claude Code CLI protocol
- `lib/agent_ex/protocol/open_code.ex` — OpenCode CLI protocol
- `lib/agent_ex/loop/stages/cli_executor.ex` — CLI executor stage

### Open Questions — Answered

#### Session Persistence

**Answer**: Use Mneme for session persistence. The CLI protocol implementations store session state in `:persistent_term` for runtime access. For persistence across process restarts, we can serialize the session config to Mneme's `mneme_entries` with entry type `session_summary` or a dedicated schema. The session ID can be stored to allow resumption.

#### MCP Integration

**Answer**: Reuse Worth's MCP implementation. The CLI protocols can delegate tool execution to `Worth.Mcp.Gateway` when a tool call is received. The `ToolExecutor` stage already has MCP integration — CLI protocols simply need to return tool calls in the response and let the existing tool executor handle them.

#### Cost Tracking for Subscription Agents

**Answer**: Track usage via session time limits and periodic limits (hourly/daily/weekly). The profile config includes `session_cost_limit_usd` and `session_duration_limit_ms` for per-session limits. For periodic limits, the callbacks should include `on_usage_update` that reports:

```elixir
%{
  period: :hourly | :daily | :weekly,
  used_ms: 120_000,           # milliseconds used this period
  limit_ms: 3_600_000,        # limit for this period
  used_usd: 2.50,             # abstract cost used (if applicable)
  limit_usd: 10.0,            # cost limit for this period
  remaining_ms: 3_480_000,   # milliseconds remaining
  remaining_usd: 7.50         # cost remaining
}
```

The frontend can display progress bars for these limits.

#### Streaming

**Answer**: Yes, add streaming callback. The `on_stream_message` callback is called with partial data during response streaming. The CLI executor already has `stream_completion/2` — extend this for incremental streaming.

## Related Decisions

- See `decisions.md` for transport vs protocol distinction
- See `multi-mode-loop-proposal.md` for profile evolution