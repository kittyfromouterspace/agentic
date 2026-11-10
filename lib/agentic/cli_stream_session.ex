defmodule Agentic.CLI.StreamSession do
  @moduledoc """
  Spawn-and-stream session runner for CLI agent protocols.

  The `Protocol` modules are turn-synchronous by design: `send/3` blocks
  until the final `result` envelope and the caller never sees intermediate
  chunks. Harnesses that *watch* an agent work (control planes, desktops,
  transcripts) need the opposite: spawn once, stream every chunk as it
  arrives, and optionally inject extra stdin turns (answers/steer) while the
  CLI is running.

  This module owns that lifecycle:

    * the session's port is opened inside a dedicated owner task, so the
      capture loop always owns the port and its lifetime
    * a capture loop streams chunks into `on_chunk`, wraps up with
      `on_exit`, and pings `on_heartbeat` at a fixed interval while the
      process lives (session sweeps can key off that)
    * `send_stdin/3` lets the harness inject further user envelopes into a
      still-open stdin (claude stream-json); opencode turns are per-process
      one-shots by protocol design, so only fresh sessions accept prompts
      there
    * all protocol knowledge (CLI args, model flags, gateway env, the
      stream-json envelope format, the bubblewrap sandbox) stays inside the
      protocol modules — StreamSession is transport only.

  Per-protocol spawn shapes come from agentic itself:

    * `:claude_code` — `Agentic.Protocol.ClaudeCode.start/2` opens a
      long-lived port running `-p --input-format stream-json`
    * `:opencode` — `Agentic.Protocol.OpenCode.build_config/1` plus
      `turn_spawn_args/2`: `sh -c 'exec opencode … "$AGENTIC_PROMPT"
      </dev/null>'` (the CLI reads stdin to EOF, so the prompt must be an
      env var and stdin must terminate)

  ## Example

      {:ok, session_id} =
        Agentic.CLI.StreamSession.start(:claude_code, %{model: model},
          %{metadata: %{workspace: workspace}},
          initial_prompt: "fix the failing test",
          on_chunk: fn chunk -> Log.append(chunk) end,
          on_exit: fn status -> Log.finish(status) end,
          on_heartbeat: fn -> Registry.ping() end
        )

      extra =
        Agentic.Protocol.ClaudeCode.format_messages(
          [%{"role" => "user", "content" => "use port 4000"}],
          %{}
        )

      Agentic.CLI.StreamSession.send_stdin(session_id, extra, "\n")
  """

  require Logger

  alias Agentic.Protocol

  @heartbeat_default_ms 30_000

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Spawn a session and start streaming. Returns `{:ok, session_id}`.

  ## Options

    * `:initial_prompt` — first prompt; wrapped per protocol (claude: a
      stream-json user envelope over stdin; opencode: `$AGENTIC_PROMPT`)
    * `:on_chunk` — `(binary() -> any())`, every stdout/stderr chunk
    * `:on_exit` — `(status :: integer() | :closed -> any())`
    * `:on_heartbeat` — `(-> any())`, called every `:heartbeat_ms` while
      alive
    * `:heartbeat_ms` — heartbeat cadence (default 30_000)
    * `:stderr_to_stdout` — merge stderr into the chunk stream (default
      true)
  """
  @spec start(:claude_code | :opencode, map(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start(kind, backend_config, ctx, opts \\ [])
      when kind in [:claude_code, :opencode] and is_map(backend_config) and is_map(ctx) and
             is_list(opts) do
    session_id = "stream_#{kind}_#{:erlang.unique_integer([:positive])}"
    opts_map = Map.new(opts)

    owner =
      spawn(fn ->
        spawn_and_stream(kind, backend_config, ctx, opts_map, session_id)
      end)

    :persistent_term.put(state_key(session_id), %{owner: owner, port: nil})
    {:ok, session_id}
  end

  @doc "Push extra content into a session's open stdin (claude stream-json)."
  @spec send_stdin(String.t(), iodata(), iodata()) :: :ok | {:error, :session_not_active}
  def send_stdin(session_id, iodata, suffix \\ []) do
    case :persistent_term.get(state_key(session_id), :gone) do
      %{owner: owner} ->
        send(owner, {:stream_session_stdin, session_id, iodata, suffix})
        :ok

      _ ->
        {:error, :session_not_active}
    end
  end

  @doc "Tear down a session — the owner closes the port on its way out."
  @spec stop(String.t()) :: :ok | {:error, :session_not_active}
  def stop(session_id) do
    case :persistent_term.get(state_key(session_id), :gone) do
      %{owner: owner} ->
        send(owner, {:stream_session_stop, session_id})
        :ok

      _ ->
        {:error, :session_not_active}
    end
  end

  @doc "Is the session's owning process alive?"
  @spec alive?(String.t()) :: boolean()
  def alive?(session_id) do
    case :persistent_term.get(state_key(session_id), :gone) do
      %{owner: owner} ->
        Process.alive?(owner)

      _ ->
        false
    end
  end

  @doc "Delegate to the protocol's own model catalogue (`list_models/0`)."
  @spec list_models(:claude_code | :opencode) :: [String.t()]
  def list_models(:claude_code), do: Protocol.ClaudeCode.list_models()
  def list_models(:opencode), do: Protocol.OpenCode.list_models()

  @doc """
  `Protocol.OpenCode.list_models_grouped/0` — models grouped by provider
  (authenticated subscriptions first) for optgroup-style pickers.
  """
  @spec list_models_grouped(:opencode) :: [{String.t(), [String.t()]}]
  def list_models_grouped(:opencode), do: Protocol.OpenCode.list_models_grouped()

  # ── Internals ───────────────────────────────────────────────────────────

  defp state_key(session_id), do: {__MODULE__, session_id}

  # The owner process runs until the process exits; state is published so
  # the harness can address stdin/stop at it later.
  defp spawn_and_stream(kind, backend_config, ctx, opts, session_id) do
    case open_session_port(kind, backend_config, ctx, opts) do
      {:ok, port, stdin} ->
        put_port(session_id, port)

        case stdin do
          data when is_binary(data) and data != "" ->
            Port.command(port, [data, "\n"])

          _ ->
            :ok
        end

        if is_function(opts[:on_heartbeat], 0) do
          Process.send_after(
            self(),
            :heartbeat,
            opts[:heartbeat_ms] || @heartbeat_default_ms
          )
        end

        capture_loop(port, session_id, opts)

      {:error, reason} ->
        abandon(session_id, opts, {:spawn_failed, reason})
    end
  end

  defp open_session_port(:claude_code, backend_config, ctx, opts) do
    # ClaudeCode.start's contract is {:ok, session_id} only; any deviation
    # is downgraded to an error rather than raising inside the owner task.
    result =
      try do
        {:ok, agentic_session_id} =
          Protocol.ClaudeCode.start(backend_config, ctx)

        %{port: port} = :persistent_term.get({Protocol.ClaudeCode, agentic_session_id})
        {:ok, port, claude_stdin(opts[:initial_prompt])}
      rescue
        e -> {:error, {:claude_session_start_failed, Exception.message(e)}}
      end

    result
  end

  defp open_session_port(:opencode, backend_config, ctx, opts) do
    config = Protocol.OpenCode.build_config(backend_config)

    {program, args, env_list} =
      Protocol.OpenCode.turn_spawn_args(config, opts[:initial_prompt] || "")

    workspace = ctx.metadata[:workspace]

    cd_opt =
      case workspace do
        w when is_binary(w) -> [{:cd, w}]
        _ -> []
      end

    port_opts =
      [:stream, :binary, :exit_status, :stderr_to_stdout, {:args, args}] ++
        cd_opt ++ [{:env, env_list}]

    {:ok, Port.open({:spawn_executable, program}, port_opts), nil}
  end

  defp claude_stdin(prompt) when is_binary(prompt) and prompt != "" do
    Protocol.ClaudeCode.format_messages([%{"role" => "user", "content" => prompt}], %{})
  end

  defp claude_stdin(_other), do: nil

  defp put_port(session_id, port) do
    :persistent_term.put(state_key(session_id), %{owner: self(), port: port})
  end

  defp abandon(session_id, opts, reason) do
    Logger.warning("StreamSession: boot failed for #{session_id}: #{inspect(reason)}")
    :persistent_term.erase(state_key(session_id))
    callback(opts, :on_exit, [reason])
    :done
  end

  defp capture_loop(port, session_id, opts) do
    receive do
      {:stream_session_stdin, ^session_id, data, suffix} ->
        Port.command(port, List.wrap(suffix) ++ List.wrap(data))
        capture_loop(port, session_id, opts)

      {:stream_session_stop, ^session_id} ->
        Port.close(port)
        capture_loop(port, session_id, opts)

      :heartbeat ->
        callback(opts, :on_heartbeat, [])
        cadence = opts[:heartbeat_ms] || @heartbeat_default_ms

        Process.send_after(self(), :heartbeat, cadence)

        capture_loop(port, session_id, opts)

      {^port, {:data, data}} ->
        callback(opts, :on_chunk, [data])
        capture_loop(port, session_id, opts)

      {:port, ^port, {:data, data}} ->
        callback(opts, :on_chunk, [data])
        capture_loop(port, session_id, opts)

      {^port, {:exit_status, status}} ->
        finish(session_id, opts, status)

      {:port, ^port, {:exit_status, status}} ->
        finish(session_id, opts, status)

      {^port, :closed} ->
        finish(session_id, opts, :closed)

      {:port, ^port, :closed} ->
        finish(session_id, opts, :closed)

      _other ->
        capture_loop(port, session_id, opts)
    end
  end

  defp finish(session_id, opts, status) do
    :persistent_term.erase(state_key(session_id))
    callback(opts, :on_exit, [status])
    :done
  end

  defp callback(opts, key, args) do
    case Map.get(opts, key) do
      fun when is_function(fun, length(args)) -> apply(fun, args)
      _ -> :ok
    end
  end
end
