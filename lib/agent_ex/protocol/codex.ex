defmodule AgentEx.Protocol.Codex do
  @moduledoc """
  Codex CLI protocol implementation.

  Communicates with Codex via subprocess using JSON streaming over
  stdin/stdout. Supports session resumption.

  ## Usage

      # Register the protocol
      AgentEx.Protocol.Registry.register(:codex, __MODULE__)

      # Use in a session
      {:ok, session_id} = AgentEx.Protocol.Codex.start(config, context)
      {:ok, response} = AgentEx.Protocol.Codex.send(session_id, messages, context)
  """

  use AgentEx.AgentProtocol.CLI

  require Logger

  @cli_name "codex"
  @default_args ["--json"]

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

  # --- AgentProtocol ---

  @impl true
  def transport_type, do: :local_agent

  @impl true
  def start(backend_config, _ctx) do
    config = build_config(backend_config)

    port =
      Port.open(
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
    Port.command(port, ["resume"] ++ session_args ++ ["\n"])
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
        Logger.info("Stopped Codex session: #{session_id}")
        :ok
    end
  rescue
    _ -> :ok
  end

  # --- Protocol parsing ---

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

  # --- Session state ---

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
