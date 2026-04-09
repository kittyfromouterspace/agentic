defmodule AgentEx.Protocol.ClaudeCode do
  @moduledoc """
  Claude Code CLI protocol implementation.

  Communicates with Claude Code via subprocess using JSON streaming over
  stdin/stdout. Supports session resumption and MCP tool integration.

  ## Usage

      # Register the protocol
      AgentEx.Protocol.Registry.register(:claude_code, __MODULE__)

      # Use in a session
      {:ok, session_id} = AgentEx.Protocol.ClaudeCode.start(config, context)
      {:ok, response} = AgentEx.Protocol.ClaudeCode.send(session_id, messages, context)
  """

  use AgentEx.AgentProtocol.CLI

  require Logger

  @cli_name "claude"
  @default_args [
    "-p",
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
    Map.merge(
      %{
        command: @cli_name,
        args: default_args() ++ (profile_config[:extra_args] || []),
        env: profile_config[:env] || %{},
        session_mode: :always,
        session_id_fields: ["session_id"],
        resume_args: resume_args(),
        system_prompt_arg: "--append-system-prompt",
        system_prompt_mode: :append,
        system_prompt_when: :first
      },
      profile_config[:cli_config] || %{}
    )
  end

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
  def start(backend_config, _ctx) do
    config = build_config(backend_config)

    port =
      Port.open(
        {:spawn_executable, :os.find_executable(config[:command]) || config[:command]},
        [:stream, :binary, :exit_status, {:args, config[:args] || []}]
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
  def parse_stream(chunk) do
    # Claude Code outputs JSON lines, potentially with partial messages
    chunk
    |> String.split("\n", trim: true)
    |> Enum.reduce(:partial, fn
      line, acc ->
        case Jason.decode(line) do
          {:ok, %{"type" => "content_block_delta", "delta" => delta}} ->
            # Accumulate partial content
            {:partial, [delta | acc]}

          {:ok, %{"type" => "content_block_stop"}} ->
            # Complete message
            content = acc |> elem(1) |> Enum.reverse() |> Enum.map_join("", &(&1["text"] || ""))
            {:message, %{"content" => content, "type" => "text"}}

          {:ok, %{"type" => "message_start", "message" => message}} ->
            {:partial, [message]}

          {:ok, %{"type" => "message_delta", "delta" => delta, "usage" => usage}} ->
            # End of message with usage
            content = acc |> elem(1) |> Enum.reverse() |> Enum.map_join("", &(&1["text"] || ""))

            {
              :message,
              %{
                "content" => content,
                "usage" => usage,
                "stop_reason" => delta["stop_reason"]
              }
            }

          {:ok, %{"type" => "error", "error" => error}} ->
            {:error, error}

          {:ok, %{"type" => type}} when type in ["ping"] ->
            # Keep reading
            acc

          _ ->
            acc
        end
    end)
  end

  @impl true
  def format_messages(messages, _ctx) do
    # Convert to Claude Code's JSON input format
    messages
    |> Enum.map(fn
      %{"role" => "system"} ->
        # Skip system messages - they go via --append-system-prompt
        nil

      %{"role" => role, "content" => content} when is_binary(content) ->
        %{
          "type" => "message",
          "role" => role,
          "content" => [
            %{
              "type" => "text",
              "text" => content
            }
          ]
        }

      %{"role" => role} ->
        %{
          "type" => "message",
          "role" => role,
          "content" => [%{"type" => "text", "text" => ""}]
        }
    end)
    |> Enum.reject(&is_nil/1)
    |> Jason.encode!()
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

            tool_calls = extract_tool_calls(new_buffer)

            {:ok,
             %{
               content: content,
               tool_calls: tool_calls,
               usage: usage,
               stop_reason: stop_reason,
               metadata: %{
                 session_id: session_id,
                 protocol: :claude_code
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

  defp extract_tool_calls(_buffer) do
    # Claude Code tool calls come as separate message types
    # Would need to parse tool_use blocks from the buffer
    []
  end
end
