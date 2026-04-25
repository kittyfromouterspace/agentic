defmodule Agentic.Protocol.ClaudeCode do
  @moduledoc """
  Claude Code CLI protocol implementation.

  Communicates with Claude Code via subprocess using JSON streaming over
  stdin/stdout. Supports session resumption and MCP tool integration.

  ## Usage

      # Register the protocol
      Agentic.Protocol.Registry.register(:claude_code, __MODULE__)

      # Use in a session
      {:ok, session_id} = Agentic.Protocol.ClaudeCode.start(config, context)
      {:ok, response} = Agentic.Protocol.ClaudeCode.send(session_id, messages, context)
  """

  use Agentic.AgentProtocol.CLI

  alias Agentic.Sandbox.Runner

  require Logger

  @cli_name "claude"
  @default_args [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--permission-mode",
    "bypassPermissions"
  ]

  # --- CLI Behaviour ---

  @impl true
  def cli_name, do: @cli_name

  @impl true
  def cli_version, do: nil

  @impl true
  def default_args, do: @default_args

  @impl true
  def resume_args,
    do: [
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--include-partial-messages",
      "--verbose",
      "--permission-mode",
      "bypassPermissions",
      "--resume"
    ]

  @impl true
  def build_config(profile_config) do
    base_env = profile_config[:env] || %{}
    env_with_gateway = Agentic.LLM.Gateway.inject_env(base_env, :anthropic)

    model_args = build_model_args(profile_config[:model])

    Map.merge(
      %{
        command: @cli_name,
        args: default_args() ++ model_args ++ (profile_config[:extra_args] || []),
        env: env_with_gateway,
        session_mode: :always,
        session_id_fields: ["session_id"],
        resume_args: resume_args() ++ model_args,
        system_prompt_arg: "--append-system-prompt",
        system_prompt_mode: :append,
        system_prompt_when: :first,
        model_arg: "--model"
      },
      profile_config[:cli_config] || %{}
    )
  end

  # Translate a route's `model_id` into a `--model <id>` arg pair for the
  # CLI. The `Agentic.LLM.Canonical` mapping table covers both short
  # aliases (`sonnet`/`opus`) and dated IDs, so we accept whatever the
  # router resolved without needing a per-protocol alias map.
  defp build_model_args(nil), do: []
  defp build_model_args(""), do: []
  defp build_model_args(model_id) when is_binary(model_id), do: ["--model", model_id]

  # --- AgentProtocol ---

  @impl true
  def transport_type, do: :local_agent

  @impl true
  def available? do
    System.find_executable(@cli_name) != nil
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
      arg = config[:system_prompt_arg] || "--append-system-prompt"
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

  @impl true
  def start(backend_config, ctx) do
    config = build_config(backend_config)

    workspace = ctx.metadata[:workspace] || File.cwd!()
    allowed_roots = ctx.metadata[:allowed_roots] || [workspace]
    agent_dirs = allowed_roots -- [workspace]

    {exe, args, extra_env} =
      Runner.wrap_executable(
        :os.find_executable(to_charlist(config[:command])) || config[:command],
        config[:args] || [],
        workspace: workspace,
        agent_dirs: agent_dirs
      )

    env =
      merge_env(config, config[:env] || %{})
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open(
        {:spawn_executable, exe},
        [:stream, :binary, :exit_status, {:args, args}, {:env, env} | extra_env]
      )

    session_id =
      :crypto.strong_rand_bytes(16)
      |> :binary.bin_to_list()
      |> Enum.map_join(&Integer.to_string(&1, 16))

    # Store port and config for this session
    session_state = %{
      port: port,
      config: config,
      started_at: DateTime.utc_now(),
      buffer: ""
    }

    :persistent_term.put({__MODULE__, session_id}, session_state)

    Logger.info("Started Claude Code session: #{session_id}")

    {:ok, session_id}
  end

  @impl true
  def send(session_id, messages, ctx) do
    session_state = fetch_session!(session_id)
    _config = session_state.config

    # Format messages for Claude Code
    formatted = format_messages(messages, ctx)

    # Send to stdin
    port = session_state.port
    Port.command(port, [formatted, "\n"])

    # Collect response
    collect_response(session_id, session_state, "")
  end

  @impl true
  def resume(session_id, messages, ctx) do
    session_state = fetch_session!(session_id)
    config = session_state.config

    # Build resume args
    resume_args = config[:resume_args] || config[:args] || []

    # Add session ID
    session_args = format_session_arg(session_id, config)
    _args = resume_args ++ session_args

    # Reopen port with new args if needed
    port = session_state.port

    # Format messages for resume
    formatted = format_messages(messages, ctx)

    Port.command(port, [formatted, "\n"])

    collect_response(session_id, session_state, "")
  end

  @impl true
  def stop(session_id) do
    case :persistent_term.get({__MODULE__, session_id}, nil) do
      nil ->
        :ok

      session_state ->
        port = session_state.port
        Port.close(port)
        :persistent_term.erase({__MODULE__, session_id})
        Logger.info("Stopped Claude Code session: #{session_id}")
        :ok
    end
  rescue
    _ -> :ok
  end

  # --- Protocol parsing ---

  @impl true
  def parse_stream(buffer) do
    # Claude Code emits one JSON record per line. The shapes we care about:
    #   %{"type" => "system", ...}                — session state, init, status
    #   %{"type" => "stream_event", "event" => %{"type" => inner, ...}}
    #     where `inner` is one of: message_start, content_block_start,
    #     content_block_delta, content_block_stop, message_delta, message_stop
    #   %{"type" => "assistant", "message" => %{"content" => [...]}}
    #   %{"type" => "result", "subtype" => "success" | ...,
    #     "result" => text, "usage" => usage, "stop_reason" => reason}
    #   %{"type" => "error", "error" => ...}
    #
    # We wait for a terminal `result` record to yield `{:message, ...}`.
    # The buffer may end in a partial line; undecodable lines are skipped
    # until the next chunk completes them.

    events = decode_lines(buffer)

    cond do
      err = Enum.find(events, &match?(%{"type" => "error"}, &1)) ->
        {:error, err["error"] || err}

      result = Enum.find(events, &match?(%{"type" => "result"}, &1)) ->
        build_message(result, events)

      true ->
        :partial
    end
  end

  defp decode_lines(buffer) do
    buffer
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case line |> String.trim() |> decode_line() do
        {:ok, json} -> [json]
        :skip -> []
      end
    end)
  end

  defp decode_line(""), do: :skip

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> :skip
    end
  end

  defp build_message(result, events) do
    if result["is_error"] do
      {:error, result["result"] || result["error"] || "claude cli reported error"}
    else
      {:message,
       %{
         "content" => extract_text(events, result),
         "usage" => result["usage"] || %{},
         "stop_reason" => result["stop_reason"],
         "total_cost_usd" => result["total_cost_usd"]
       }}
    end
  end

  # Prefer the text baked into the final `assistant` message (authoritative),
  # then the `result.result` field, then accumulated text_delta chunks.
  defp extract_text(events, result) do
    case last_assistant_text(events) do
      text when is_binary(text) and text != "" -> text
      _ -> result["result"] || accumulated_deltas(events)
    end
  end

  defp last_assistant_text(events) do
    events
    |> Enum.filter(&match?(%{"type" => "assistant"}, &1))
    |> List.last()
    |> case do
      nil ->
        nil

      %{"message" => %{"content" => content}} when is_list(content) ->
        content
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => t} when is_binary(t) -> [t]
          _ -> []
        end)
        |> Enum.join("")

      _ ->
        nil
    end
  end

  defp accumulated_deltas(events) do
    events
    |> Enum.flat_map(fn
      %{"type" => "stream_event", "event" => %{"type" => "content_block_delta", "delta" => delta}} ->
        case delta do
          %{"type" => "text_delta", "text" => t} when is_binary(t) -> [t]
          %{"text" => t} when is_binary(t) -> [t]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.join("")
  end

  @impl true
  def format_messages(messages, _ctx) do
    # Claude Code's stream-json input expects one envelope per line, shaped as
    #   {"type":"user","message":{"role":"user","content":"..."}}
    # System messages go via --append-system-prompt instead.
    messages
    |> Enum.map(fn
      %{"role" => "system"} ->
        nil

      %{"role" => role, "content" => content} when is_binary(content) ->
        %{"type" => "user", "message" => %{"role" => role, "content" => content}}

      %{"role" => role, "content" => content} when is_list(content) ->
        %{"type" => "user", "message" => %{"role" => role, "content" => content}}

      %{"role" => role} ->
        %{"type" => "user", "message" => %{"role" => role, "content" => ""}}
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n", &Jason.encode!/1)
  end

  # --- Session state management ---

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
            # Extract content and tool calls
            content = message["content"] || ""
            usage = message["usage"] || %{}
            stop_reason = message["stop_reason"]
            total_cost_usd = message["total_cost_usd"]

            tool_calls = extract_tool_calls(new_buffer)

            emit_cli_complete(session_id, :claude_code, usage, total_cost_usd)

            {:ok,
             %{
               content: content,
               tool_calls: tool_calls,
               usage: usage,
               stop_reason: stop_reason,
               metadata: %{
                 session_id: session_id,
                 protocol: :claude_code,
                 total_cost_usd: total_cost_usd
               }
             }}

          :partial ->
            collect_response(session_id, session_state, new_buffer)

          {:error, reason} ->
            {:error, reason}
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

  defp extract_tool_calls(buffer) do
    buffer
    |> decode_lines()
    |> Enum.filter(&match?(%{"type" => "assistant"}, &1))
    |> List.last()
    |> case do
      %{"message" => %{"content" => content}} when is_list(content) ->
        content
        |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
        |> Enum.map(fn %{"id" => id, "name" => name} = tu ->
          %{"id" => id, "name" => name, "input" => tu["input"] || %{}}
        end)

      _ ->
        []
    end
  end

  # Emit `[:agentic, :protocol, :cli, :complete]` carrying the CLI's
  # self-reported `total_cost_usd` and token counts. SpendTracker
  # treats the gateway tap as source of truth (it sees the actual
  # HTTP request the CLI subprocess makes) and uses this event only
  # for discrepancy warnings — see §5.3 of the multi-pathway routing
  # proposal.
  defp emit_cli_complete(session_id, protocol, usage, total_cost_usd) do
    actual_cost =
      case total_cost_usd do
        n when is_number(n) and n > 0 ->
          try do
            Money.from_float(:USD, n)
          rescue
            _ -> nil
          end

        _ ->
          nil
      end

    Agentic.Telemetry.event(
      [:agentic, :protocol, :cli, :complete],
      %{
        input_tokens: get_token(usage, ["input_tokens", "prompt_tokens"]),
        output_tokens: get_token(usage, ["output_tokens", "completion_tokens"]),
        cache_read_tokens: get_token(usage, ["cache_read_input_tokens", "cache_read"]),
        cache_write_tokens: get_token(usage, ["cache_creation_input_tokens", "cache_write"])
      },
      %{
        session_id: session_id,
        protocol: protocol,
        provider: protocol,
        actual_cost: actual_cost,
        cli_reported_cost_usd: total_cost_usd
      }
    )
  rescue
    _ -> :ok
  end

  defp get_token(usage, keys) when is_map(usage) do
    Enum.find_value(keys, 0, fn k ->
      case Map.get(usage, k) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end) || 0
  end

  defp get_token(_, _), do: 0
end
