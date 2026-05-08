defmodule Agentic.Protocol.OpenCode do
  @moduledoc """
  OpenCode CLI protocol implementation.

  Communicates with OpenCode via subprocess using JSON streaming over
  stdin/stdout. Supports session resumption and MCP tool integration.

  ## Usage

      # Register the protocol
      Agentic.Protocol.Registry.register(:opencode, __MODULE__)

      # Use in a session
      {:ok, session_id} = Agentic.Protocol.OpenCode.start(config, context)
      {:ok, response} = Agentic.Protocol.OpenCode.send(session_id, messages, context)
  """

  use Agentic.AgentProtocol.CLI

  alias Agentic.Sandbox.Runner

  require Logger

  @cli_name "opencode"
  @default_args ["--mode", "agent", "--output", "json"]

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
        session_id_fields: ["session_id"],
        system_prompt_mode: :append,
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
    arg = config[:session_arg] || "--session-id"
    [arg, session_id]
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
  def transport_type, do: :local_agent

  @impl true
  def start(backend_config, ctx) do
    config = build_config(backend_config)

    workspace = ctx.metadata[:workspace] || File.cwd!()
    allowed_roots = ctx.metadata[:allowed_roots] || [workspace]
    agent_dirs = allowed_roots -- [workspace]

    # Add AgentFS bind mounts if present
    agent_dirs =
      case ctx.metadata[:agent_fs_bind_mounts] do
        nil -> agent_dirs
        mounts -> agent_dirs ++ mounts
      end

    {exe, args, extra_env} =
      Runner.wrap_executable(
        :os.find_executable(to_charlist(config[:command])) || config[:command],
        config[:args] || [],
        workspace: workspace,
        agent_dirs: agent_dirs
      )

    env =
      config
      |> merge_env(config[:env] || %{})
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open(
        {:spawn_executable, exe},
        [:stream, :binary, :exit_status, {:args, args}, {:env, env} | extra_env]
      )

    session_id =
      16
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map_join(&Integer.to_string(&1, 16))

    session_state = %{
      port: port,
      config: config,
      started_at: DateTime.utc_now(),
      buffer: ""
    }

    :persistent_term.put({__MODULE__, session_id}, session_state)

    Logger.info("Started OpenCode session: #{session_id}")

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

    # OpenCode uses --resume flag
    port = session_state.port
    Port.command(port, ["--resume", " "] ++ session_args ++ ["\n"])
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
        Logger.info("Stopped OpenCode session: #{session_id}")
        :ok
    end
  rescue
    _ -> :ok
  end

  # --- Protocol parsing ---

  @impl true
  def parse_stream(chunk) do
    # OpenCode outputs JSON lines
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

          {:ok, _} ->
            acc

          _ ->
            acc
        end
    end)
  end

  @impl true
  def format_messages(messages, _ctx) do
    # Convert to OpenCode's JSON format
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

  # --- Session state ---

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
                 protocol: :opencode
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
