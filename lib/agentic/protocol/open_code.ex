defmodule Agentic.Protocol.OpenCode do
  @moduledoc """
  OpenCode CLI protocol implementation.

  Drives the real `opencode` CLI one-shot per turn: the turn prompt is
  passed as the final positional argument and the CLI's JSON event stream
  (`opencode run --format json`) is parsed for the assistant text. Session
  continuity uses opencode's own session ids (`-s <sessionID>`) captured
  from the event stream — each turn spawns a fresh process, because the
  CLI reads stdin to EOF and a port-held stdin pipe can never deliver it.

  ## Usage

      # Register the protocol
      Agentic.Protocol.Registry.register(:opencode, __MODULE__)

      # Use in a session
      {:ok, session_id} = Agentic.Protocol.OpenCode.start(config, context)
      {:ok, response} = Agentic.Protocol.OpenCode.resume(session_id, messages, context)
  """

  use Agentic.AgentProtocol.CLI

  alias Agentic.Sandbox.Runner

  require Logger

  @cli_name "opencode"
  @default_args ["run", "--format", "json"]

  # --- CLI Behaviour ---

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
    base_env = profile_config[:env] || %{}
    env_with_gateway = Agentic.LLM.Gateway.inject_env(base_env, :openai)

    model_args = build_model_args(profile_config[:model])

    Map.merge(
      %{
        command: @cli_name,
        args: default_args() ++ model_args ++ (profile_config[:extra_args] || []),
        env: env_with_gateway,
        session_mode: :always,
        session_id_fields: ["sessionID"],
        system_prompt_mode: :replace,
        system_prompt_when: :first,
        model_arg: "--model"
      },
      profile_config[:cli_config] || %{}
    )
  end

  defp build_model_args(nil), do: []
  defp build_model_args(""), do: []
  defp build_model_args(model_id) when is_binary(model_id), do: ["--model", model_id]

  @impl true
  def available? do
    System.find_executable(@cli_name) != nil
  end

  @impl true
  def format_session_arg(session_id, config) do
    arg = config[:session_arg] || "--session"
    [arg, session_id]
  end

  @impl true
  def extract_session_id(response, config) do
    fields = config[:session_id_fields] || ["sessionID"]

    Enum.find_value(fields, fn field ->
      response[field] || response[:sessionID]
    end)
  end

  @impl true
  def format_system_prompt(system_prompt, _is_first, _config) do
    # OpenCode has no CLI flag for system prompts — we prepend it to the
    # turn prompt in `format_messages/2` instead.
    system_prompt
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
  def transport_type, do: :local_agent

  # --- Session lifecycle ---

  @impl true
  def start(backend_config, ctx) do
    config = build_config(backend_config)
    workspace = ctx.metadata[:workspace] || File.cwd!()

    session_id =
      16
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map_join(&Integer.to_string(&1, 16))

    session_state = %{
      config: config,
      workspace: workspace,
      opencode_session_id: nil,
      started_at: DateTime.utc_now()
    }

    :persistent_term.put({__MODULE__, session_id}, session_state)

    Logger.info("Started OpenCode session: #{session_id}")

    {:ok, session_id}
  end

  @impl true
  def send(session_id, messages, ctx) do
    run_turn(session_id, messages, ctx, false)
  end

  @impl true
  def resume(session_id, messages, ctx) do
    run_turn(session_id, messages, ctx, true)
  end

  @impl true
  def stop(session_id) do
    case :persistent_term.get({__MODULE__, session_id}, nil) do
      nil ->
        :ok

      _session_state ->
        :persistent_term.erase({__MODULE__, session_id})
        Logger.info("Stopped OpenCode session: #{session_id}")
        :ok
    end
  rescue
    _ -> :ok
  end

  # --- One-shot turn execution ---

  defp run_turn(session_id, messages, ctx, resume?) do
    session_state = fetch_session!(session_id)
    config = session_state.config
    prompt = format_messages(messages, ctx)

    session_args =
      if resume? and session_state.opencode_session_id do
        format_session_arg(session_state.opencode_session_id, config)
      else
        []
      end

    argv = config[:args] ++ session_args
    exe = :os.find_executable(to_charlist(config[:command]))

    {exe, argv, extra_port_opts} =
      Runner.wrap_executable(exe || config[:command], argv,
        workspace: session_state.workspace,
        agent_dirs: []
      )

    script =
      "exec " <>
        Enum.join([exe | argv], " ") <>
        ~S( "$AGENTIC_PROMPT" </dev/null)

    env =
      config
      |> merge_env(%{})
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      |> Enum.concat([{~c"AGENTIC_PROMPT", String.to_charlist(prompt)}])

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :stream,
          :binary,
          :exit_status,
          :hide,
          {:args, ["-c", script, "sh"]},
          {:cd, session_state.workspace},
          {:env, env}
        ] ++ extra_port_opts
      )

    timeout = config[:response_timeout_ms] || 300_000
    acc = %{content: [], tokens: nil, reason: nil, session_id: nil, tail: []}

    try do
      collect_turn(port, session_id, session_state, "", acc, timeout)
    after
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end
  end

  defp collect_turn(port, session_id, session_state, buffer, acc, timeout) do
    receive do
      {^port, {:data, chunk}} ->
        {buffer, acc} = handle_chunk(buffer <> chunk, acc)
        collect_turn(port, session_id, session_state, buffer, acc, timeout)

      {^port, {:exit_status, 0}} ->
        finish_turn(session_id, session_state, acc, nil)

      {^port, {:exit_status, code}} ->
        {:error, {:exit_status, code, Enum.take(acc.tail, -5)}}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp finish_turn(session_id, session_state, acc, _extra) do
    content = acc.content |> Enum.reverse() |> Enum.join("\n")

    if content == "" do
      {:error, :no_output}
    else
      # Remember opencode's own session id so the next turn resumes it.
      if acc.session_id do
        :persistent_term.put({__MODULE__, session_id}, %{
          session_state
          | opencode_session_id: acc.session_id
        })
      end

      usage = %{
        input_tokens: get_in(acc.tokens || %{}, ["input"]) || 0,
        output_tokens: get_in(acc.tokens || %{}, ["output"]) || 0
      }

      {:ok,
       %{
         content: content,
         tool_calls: [],
         usage: usage,
         stop_reason: acc.reason || "stop",
         metadata: %{
           session_id: session_id,
           opencode_session_id: acc.session_id,
           protocol: :opencode
         }
       }}
    end
  end

  # --- Event stream parsing ---

  # Buffers partial lines; returns {remaining_buffer, updated_acc}.
  defp handle_chunk(chunk, acc) do
    case String.split(chunk, "\n") do
      parts when is_list(parts) ->
        {complete, [remaining]} = Enum.split(parts, -1)
        acc = Enum.reduce(complete, acc, &handle_line/2)
        {remaining, acc}

      _ ->
        {chunk, acc}
    end
  end

  defp handle_line(line, acc) do
    case Jason.decode(line) do
      {:ok, %{"type" => "text", "part" => %{"text" => text}}} ->
        Map.update!(acc, :content, &[text | &1])

      {:ok, %{"type" => "step_finish", "part" => part}} ->
        acc
        |> Map.put(:reason, part["reason"])
        |> Map.put(:tokens, part["tokens"])
        |> put_sid(part)

      {:ok, %{"type" => "error", "message" => message}} ->
        Map.update!(acc, :content, &["[error] " <> message | &1])

      {:ok, event} ->
        put_sid(acc, event)

      _ ->
        acc
    end
  end

  defp put_sid(acc, %{"sessionID" => sid}) when is_binary(sid),
    do: Map.put_new(acc, :session_id, sid)

  defp put_sid(acc, _event), do: acc

  @doc """
  Statelessly map one complete JSON event line (compatibility helper —
  the turn collector does its own line-buffered accumulation).
  """
  @impl true
  def parse_stream(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "text", "part" => %{"text" => text}}} ->
        {:message, %{"content" => text}}

      {:ok, %{"type" => "step_finish"}} ->
        :eof

      {:ok, %{"type" => "error", "message" => message}} ->
        {:error, message}

      _ ->
        :partial
    end
  end

  @doc """
  Flatten the turn's messages into the plain-text prompt the CLI expects:
  an optional system prompt, then the latest user message. Prior turns are
  omitted — opencode's own session history carries them (via `-s`).
  """
  @impl true
  def format_messages(messages, _ctx) when is_list(messages) do
    system = find_role(messages, "system")
    user = find_role(messages, "user") || find_role(messages, "internal") || ""

    case system do
      nil -> user
      "" -> user
      system -> "#{system}\n\n---\n\n#{user}"
    end
  end

  defp find_role(messages, role) do
    # CLIExecutor may deliver the system entry as {"system", content}
    # (tuple) or as a %{"role" => ..., "content" => ...} map.
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => ^role, "content" => content} -> content
      {^role, content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  # --- Session state ---

  defp fetch_session!(session_id) do
    case :persistent_term.get({__MODULE__, session_id}, nil) do
      nil -> raise "Session not found: #{session_id}"
      state -> state
    end
  end
end
