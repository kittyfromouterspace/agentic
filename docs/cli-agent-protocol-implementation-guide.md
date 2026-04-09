# CLI Agent Protocol Implementation Guide

A practical guide for implementing new CLI-based agent protocols in AgentEx, based on patterns from ClaudeCode and OpenCode.

## Overview

CLI agent protocols communicate with local agent CLIs (like `claude`, `codex`, `opencode`) via subprocesses using JSON streaming over stdin/stdout. They are stateful — sessions persist across multiple message turns.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      AgentEx Loop Stages                                 │
├─────────────────────────────────────────────────────────────────────────┤
│  ContextGuard → ProgressInjector → CLIExecutor → ModeRouter → ...      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      CLIExecutor Stage                                   │
│  - Resolves protocol from profile                                        │
│  - Ensures session is started                                            │
│  - Sends messages, updates context                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Your Protocol Module                                  │
│  use AgentEx.AgentProtocol.CLI                                           │
│                                                                         │
│  Lifecycle:    start() → send() → resume() → stop()                     │
│  Formatting:   format_messages(), parse_stream()                        │
│  Config:       build_config(), cli_name(), default_args()               │
└─────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

Create a new file in `lib/agent_ex/protocol/`:

```elixir
defmodule AgentEx.Protocol.Codex do
  use AgentEx.AgentProtocol.CLI

  require Logger

  @cli_name "codex"
  @default_args ["--json"]

  # --- Required CLI Callbacks ---

  @impl true
  def cli_name, do: @cli_name

  @impl true
  def cli_version, do: nil

  @impl true
  def default_args, do: @default_args

  @impl true
  def resume_args, do: []

  @impl true
  def build_config(profile_config) do
    Map.merge(
      %{
        command: @cli_name,
        args: default_args() ++ (profile_config[:extra_args] || []),
        env: profile_config[:env] || %{},
        session_mode: :always,
        session_id_fields: ["session_id"],
        system_prompt_mode: :append,
        system_prompt_when: :first
      },
      profile_config[:cli_config] || %{}
    )
  end

  # --- Required AgentProtocol Callbacks ---

  @impl true
  def transport_type, do: :local_agent

  @impl true
  def available? do
    System.find_executable(@cli_name) != nil
  end

  @impl true
  def start(backend_config, _ctx) do
    config = build_config(backend_config)

    port = Port.open(
      {:spawn_executable, :os.find_executable(config[:command]) || config[:command]},
      [:stream, :binary, :exit_status, {:args, config[:args] || []}]
    )

    session_id = generate_session_id()

    session_state = %{
      port: port,
      config: config,
      started_at: DateTime.utc_now(),
      buffer: ""
    }

    :persistent_term.put({__MODULE__, session_id}, session_state)

    Logger.info("Started Codex session: #{session_id}")

    {:ok, session_id}
  end

  @impl true
  def send(session_id, messages, ctx) do
    session_state = fetch_session!(session_id)
    _config = session_state.config

    formatted = format_messages(messages, ctx)

    port = session_state.port
    Port.command(port, [formatted, "\n"])

    collect_response(session_id, session_state, "")
  end

  @impl true
  def resume(session_id, messages, ctx) do
    session_state = fetch_session!(session_id)
    config = session_state.config

    formatted = format_messages(messages, ctx)
    session_args = format_session_arg(session_id, config)

    port = session_state.port
    Port.command(port, ["--resume"] ++ session_args ++ ["\n"])
    Port.command(port, [formatted, "\n"])

    collect_response(session_id, session_state, "")
  end

  @impl true
  def stop(session_id) do
    case :persistent_term.get({__MODULE__, session_id}, nil) do
      nil -> :ok
      session_state ->
        port = session_state.port
        Port.close(port)
        :persistent_term.erase({__MODULE__, session_id})
        Logger.info("Stopped Codex session: #{session_id}")
        :ok
    end
  rescue
    _ -> :ok
  end

  # --- Protocol-Specific Callbacks ---

  @impl true
  def parse_stream(chunk) do
    chunk
    |> String.split("\n", trim: true)
    |> Enum.reduce(:partial, fn
      line, acc ->
        case Jason.decode(line) do
          {:ok, %{"type" => "response", "content" => content}} ->
            {:message, %{"content" => content}}

          {:ok, %{"type" => "tool_call", "name" => name, "input" => input}} ->
            {:message, %{"tool_calls" => [%{"name" => name, "input" => input}]}}

          {:ok, %{"type" => "error", "message" => message}} ->
            {:error, message}

          {:ok, %{"type" => "done"}} ->
            :eof

          _ ->
            acc
        end
    end)
  end

  @impl true
  def format_messages(messages, _ctx) do
    messages
    |> Enum.map(fn
      %{"role" => role, "content" => content} when is_binary(content) ->
        %{
          "type" => "message",
          "role" => role,
          "content" => content
        }
    end)
    |> Jason.encode!()
  end

  @impl true
  def format_session_arg(session_id, config) do
    case config[:session_arg] || "--session-id" do
      arg -> [arg, session_id]
    end
  end

  @impl true
  def extract_session_id(response, config) do
    fields = config[:session_id_fields] || ["session_id"]
    Enum.find_value(fields, fn field ->
      response[field] || response[:session_id]
    end)
  end

  @impl true
  def format_system_prompt(system_prompt, is_first, config) do
    _mode = config[:system_prompt_mode] || :append
    when_mode = config[:system_prompt_when] || :first

    should_send =
      case when_mode do
        :always -> true
        :first -> is_first
        :never -> false
      end

    if should_send do
      arg = config[:system_prompt_arg] || "--system-prompt"
      [arg, system_prompt]
    else
      nil
    end
  end

  @impl true
  def merge_env(config, extra_env) do
    base =
      config[:env]
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {String.upcase(k), v} end)

    clear = config[:clear_env] || []

    extra =
      extra_env
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {String.upcase(k), v} end)

    filtered_clear = Enum.map(clear, &String.upcase/1)

    base
    |> Enum.reject(fn {k, _} -> k in filtered_clear end)
    |> Enum.concat(extra)
  end

  # --- Private Helpers ---

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> :binary.bin_to_list()
    |> Enum.map_join(&Integer.to_string(&1, 16))
  end

  defp fetch_session!(session_id) do
    case :persistent_term.get({__MODULE__, session_id}, nil) do
      nil -> raise "Session not found: #{session_id}"
      state -> state
    end
  end

  defp collect_response(session_id, session_state, buffer) do
    receive do
      {port, {:data, chunk}} when port == session_state.port ->
        new_buffer = buffer <> chunk

        case parse_stream(new_buffer) do
          {:message, message} ->
            content = message["content"] || ""
            tool_calls = message["tool_calls"] || []

            {:ok,
             %{
               content: content,
               tool_calls: tool_calls,
               usage: %{},
               stop_reason: "end_turn",
               metadata: %{
                 session_id: session_id,
                 protocol: :codex
               }
             }}

          :partial ->
            collect_response(session_id, session_state, new_buffer)

          {:error, reason} ->
            {:error, reason}

          :eof ->
            {:ok, %{content: buffer, tool_calls: [], usage: %{}}}
        end

      {port, {:exit_status, status}} when port == session_state.port ->
        {:error, {:exit_status, status}}

      _ ->
        collect_response(session_id, session_state, buffer)
    after
      120_000 ->
        {:error, :timeout}
    end
  end
end
```

## Required Callbacks

### CLI Behaviour (AgentEx.AgentProtocol.CLI)

| Callback | Returns | Description |
|----------|---------|-------------|
| `cli_name` | `String.t()` | CLI binary name (e.g., `"codex"`) |
| `cli_version` | `String.t() \| nil` | Version string for debugging |
| `default_args` | `[String.t()]` | CLI args for fresh sessions |
| `resume_args` | `[String.t()]` | CLI args when resuming session |
| `build_config(profile_config)` | `cli_config()` | Build full CLI config from profile |
| `format_session_arg(session_id, config)` | `[String.t()]` | Format `--session-id` flag |
| `extract_session_id(response, config)` | `String.t() \| nil` | Parse session ID from output |
| `format_system_prompt(prompt, is_first, config)` | `[String.t()] \| nil` | Format system prompt arg |
| `merge_env(config, extra_env)` | `[{String.t(), String.t()}]` | Merge environment variables |

### AgentProtocol (AgentEx.AgentProtocol)

| Callback | Returns | Description |
|----------|---------|-------------|
| `transport_type` | `:local_agent` | Must return `:local_agent` for CLI |
| `available?` | `boolean()` | Check if CLI is installed |
| `start(backend_config, ctx)` | `{:ok, session_id} \| {:error, term()}` | Spawn subprocess |
| `send(session_id, messages, ctx)` | `{:ok, response} \| {:error, term()}` | Send messages |
| `resume(session_id, messages, ctx)` | `{:ok, response} \| {:error, term()}` | Resume session |
| `stop(session_id)` | `:ok \| {:error, term()}` | Cleanup |
| `parse_stream(chunk)` | `{:message, map()} \| :partial \| :eof \| {:error, term()}` | Parse streaming response |
| `format_messages(messages, ctx)` | `iodata()` | Convert to wire format |

## Protocol Response Format

All protocol implementations must return this response structure:

```elixir
%{
  content: String.t(),              # Text response
  tool_calls: [%{
    "name" => String.t(),
    "input" => map()
  }],                                # Tool calls from agent
  usage: %{                          # Token usage (can be empty for CLI)
    input: non_neg_integer(),
    output: non_neg_integer()
  },
  stop_reason: String.t() | nil,    # Why agent stopped
  metadata: %{                       # Protocol-specific metadata
    session_id: String.t(),
    protocol: atom()
  }
}
```

## Session State Storage

Use `:persistent_term` for runtime session storage:

```elixir
session_state = %{
  port: port,              # Elixir Port for subprocess
  config: config,          # CLI configuration
  started_at: DateTime.t(),# For duration tracking
  buffer: ""               # Streaming buffer
}

:persistent_term.put({__MODULE__, session_id}, session_state)
```

## Streaming Protocol Design

### Input Format (format_messages)

Most CLIs expect JSON. Convert AgentEx messages:

```elixir
def format_messages(messages, _ctx) do
  messages
  |> Enum.map(fn
    %{"role" => "system"} -> nil  # Skip, use --system-prompt instead
    %{"role" => role, "content" => content} ->
      %{
        "type" => "message",
        "role" => role,
        "content" => content
      }
  end)
  |> Enum.reject(&is_nil/1)
  |> Jason.encode!()
end
```

### Output Format (parse_stream)

Parse JSON lines or similar:

```elixir
def parse_stream(chunk) do
  chunk
  |> String.split("\n", trim: true)
  |> Enum.reduce(:partial, fn
    line, acc ->
      case Jason.decode(line) do
        {:ok, %{"type" => "response", "content" => content}} ->
          {:message, %{"content" => content}}

        {:ok, %{"type" => "tool_call", "name" => name, "input" => input}} ->
          {:message, %{"tool_calls" => [%{"name" => name, "input" => input}]}}

        {:ok, %{"type" => "error", "message" => message}} ->
          {:error, message}

        {:ok, %{"type" => "done"}} ->
          :eof

        _ ->
          acc  # Keep accumulating
      end
  end)
end
```

Return values:
- `{:message, map()}` — Complete response
- `:partial` — Need more data
- `:eof` — Stream finished
- `{:error, term()}` — Parse error

## CLI Configuration Schema

```elixir
@type cli_config :: %{
  required(:command) => String.t(),           # CLI binary name/path
  optional(:args) => [String.t()],            # Base CLI arguments
  optional(:env) => %{String.t() => String.t()}, # Extra env vars
  optional(:clear_env) => [String.t()],       # Env vars to remove
  optional(:session_mode) => :always | :existing | :none,
  optional(:session_id_fields) => [String.t()], # Where to find session ID
  optional(:session_args) => [String.t()],     # Extra args for session
  optional(:resume_args) => [String.t()],      # Args for resume
  optional(:system_prompt_arg) => String.t(),  # e.g., "--system-prompt"
  optional(:system_prompt_mode) => :append | :replace,
  optional(:system_prompt_when) => :first | :always | :never,
  optional(:model_arg) => String.t(),           # e.g., "--model"
  optional(:model_aliases) => %{String.t() => String.t()},
  optional(:image_arg) => String.t(),
  optional(:image_mode) => :repeat | :list,
  optional(:serialize) => boolean(),
  optional(:reliability) => map()
}
```

## Testing

Use AgentEx's test helpers to mock the protocol:

```elixir
defmodule AgentEx.Protocol.CodexTest do
  use ExUnit.Case, async: true

  alias AgentEx.Protocol.Codex

  setup do
    # Mock Port for testing
    port = Port.open({:spawn, "true"}, [:stream, :binary])
    
    %{
      port: port,
      config: %{
        command: "codex",
        args: ["--json"]
      }
    }
  end

  test "start creates session", %{config: config} do
    {:ok, session_id} = Codex.start(config, %{})
    assert is_binary(session_id)
    assert :persistent_term.get({Codex, session_id}, nil) != nil
  end

  test "format_messages converts correctly" do
    messages = [
      %{"role" => "user", "content" => "Hello"}
    ]
    
    formatted = Codex.format_messages(messages, %{})
    assert is_binary(formatted)
    assert Jason.decode!(formatted) |> hd() |> Map.get("role") == "user"
  end

  test "parse_stream handles response" do
    chunk = ~s[{"type": "response", "content": "Hello"}]
    assert Codex.parse_stream(chunk) == {:message, %{"content" => "Hello"}}
  end
end
```

## Registration

Register your protocol in the application:

```elixir
# lib/agent_ex/application.ex
def start(_type, _args) do
  # ... other children
  
  AgentEx.Protocol.Registry.register(:codex, AgentEx.Protocol.Codex)
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Add a profile for your protocol:

```elixir
# lib/agent_ex/loop/profile.ex
def config(:codex) do
  %{
    name: :codex,
    protocol: :codex,
    transport_type: :local_agent,
    stages: [
      AgentEx.Loop.Stages.ContextGuard,
      AgentEx.Loop.Stages.ProgressInjector,
      AgentEx.Loop.Stages.CLIExecutor,
      AgentEx.Loop.Stages.ModeRouter,
      AgentEx.Loop.Stages.ToolExecutor,
      AgentEx.Loop.Stages.CommitmentGate
    ],
    config: %{
      max_turns: 50,
      session_cost_limit_usd: 10.0
    }
  }
end
```

## Common Patterns

### Generate Session ID

```elixir
defp generate_session_id do
  :crypto.strong_rand_bytes(16)
  |> :binary.bin_to_list()
  |> Enum.map_join(&Integer.to_string(&1, 16))
end
```

### Timeout Handling

Default timeout is 120 seconds. Adjust per CLI:

```elixir
after
  300_000 ->  # 5 minutes for slow CLIs
    {:error, :timeout}
end
```

### Error Handling

Always handle subprocess exit:

```elixir
{port, {:exit_status, status}} when port == session_state.port ->
  {:error, {:exit_status, status}}
```

## Checklist for New Implementations

- [ ] Define `@cli_name` and `@default_args` module attributes
- [ ] Implement all required CLI callbacks
- [ ] Implement all required AgentProtocol callbacks
- [ ] Handle session state in `:persistent_term`
- [ ] Implement JSON streaming parse/format
- [ ] Handle subprocess exit status
- [ ] Register in application
- [ ] Add profile configuration
- [ ] Test with actual CLI binary

## Related Files

- `lib/agent_ex/agent_protocol.ex` — Core behaviour
- `lib/agent_ex/agent_protocol/cli.ex` — CLI behaviour  
- `lib/agent_ex/protocol/claude_code.ex` — Reference implementation
- `lib/agent_ex/protocol/open_code.ex` — Alternative implementation
- `lib/agent_ex/loop/stages/cli_executor.ex` — Uses protocols
