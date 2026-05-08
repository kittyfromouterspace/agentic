defmodule Agentic.Protocol.Codex do
  @moduledoc """
  Codex CLI protocol implementation (one-shot mode).

  Each `send/3` spawns `codex exec --json` as a single-turn subprocess:
  the concatenated conversation is sent on stdin, the process emits a
  JSONL stream describing the run, then exits. There is no long-lived
  port and no cross-turn session state — the CLI currently doesn't expose
  an ACP subcommand, so streaming multi-turn input isn't available.
  """

  use Agentic.AgentProtocol.CLI

  alias Agentic.Sandbox.Runner

  require Logger

  @cli_name "codex"
  # `--skip-git-repo-check` — workspace may not be a git repo; bwrap already
  # sandboxes the process, so codex's trusted-dir gate isn't load-bearing.
  @default_args ["exec", "--json", "--skip-git-repo-check"]
  @turn_timeout_ms 120_000

  # --- CLI Behaviour ---

  @impl true
  def cli_name, do: @cli_name

  @impl true
  def cli_version, do: nil

  @impl true
  def default_args, do: @default_args

  @impl true
  def resume_args, do: @default_args

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
        system_prompt_mode: :prepend,
        system_prompt_when: :always,
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
  def format_session_arg(_session_id, _config), do: []

  @impl true
  def extract_session_id(response, _config), do: response["thread_id"] || response[:session_id]

  @impl true
  def format_system_prompt(system_prompt, _is_first, _config) do
    # Codex has no CLI flag for system prompts in exec mode — we prepend
    # the prompt to the first user message in `format_messages/2` instead.
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

  # --- AgentProtocol ---

  @impl true
  def transport_type, do: :local_agent

  @impl true
  def start(backend_config, _ctx) do
    # One-shot: nothing to spawn up front. Stash the config so each send
    # knows which command, args, and workspace to run the turn against.
    config = build_config(backend_config)
    session_id = generate_session_id()
    :persistent_term.put({__MODULE__, session_id}, config)

    Logger.info("Prepared Codex one-shot session: #{session_id}")
    {:ok, session_id}
  end

  @impl true
  def send(session_id, messages, ctx) do
    config = fetch_config!(session_id)
    prompt = format_messages(messages, ctx)
    run_turn(session_id, config, prompt, ctx)
  end

  @impl true
  def resume(session_id, messages, ctx), do: send(session_id, messages, ctx)

  @impl true
  def stop(session_id) do
    :persistent_term.erase({__MODULE__, session_id})
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def format_messages(messages, _ctx) do
    # Flatten the chat history into a single prompt, since `codex exec`
    # is stateless.  Each turn gets a header line so the model can follow
    # the back-and-forth.
    messages
    |> Enum.map(fn
      %{"role" => role, "content" => content} when is_binary(content) ->
        "#{role}:\n#{content}"

      %{"role" => role, "content" => content} when is_list(content) ->
        text =
          content
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => t} -> [t]
            %{"text" => t} when is_binary(t) -> [t]
            _ -> []
          end)
          |> Enum.join("\n")

        "#{role}:\n#{text}"

      _ ->
        ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @impl true
  def parse_stream(buffer) do
    events = decode_lines(buffer)

    cond do
      err = Enum.find(events, &match?(%{"type" => "error"}, &1)) ->
        {:error, err["message"] || err}

      Enum.any?(events, &match?(%{"type" => "turn.completed"}, &1)) ->
        build_message(events)

      true ->
        :partial
    end
  end

  # --- Internals ---

  defp run_turn(session_id, config, prompt, ctx) do
    metadata = (is_map(ctx) && Map.get(ctx, :metadata)) || %{}
    workspace = metadata[:workspace] || config[:workspace] || File.cwd!()
    allowed_roots = metadata[:allowed_roots] || [workspace]
    agent_dirs = allowed_roots -- [workspace]

    # Add AgentFS bind mounts if present
    agent_dirs =
      case metadata[:agent_fs_bind_mounts] do
        nil -> agent_dirs
        mounts -> agent_dirs ++ mounts
      end

    executable =
      :os.find_executable(to_charlist(config[:command])) || config[:command]

    cli_args = (config[:args] || []) ++ [prompt]

    {exe, args, _extra_env} =
      Runner.wrap_executable(
        if(is_list(executable), do: List.to_string(executable), else: executable),
        cli_args,
        workspace: workspace,
        agent_dirs: agent_dirs
      )

    # `codex exec` always opens stdin — if the parent leaves it connected
    # it never sees EOF and waits forever. Wrapping the call in `sh -c` with
    # `< /dev/null` gives codex an EOF'd stdin without hijacking the BEAM's
    # own stdin or needing half-close support in Erlang ports.
    shell_cmd =
      [exe | args]
      |> Enum.map_join(" ", &shell_escape/1)
      |> Kernel.<>(" < /dev/null")

    env =
      config
      |> merge_env(config[:env] || %{})
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port_opts = [:stream, :binary, :exit_status, :stderr_to_stdout, {:args, ["-c", shell_cmd]}]

    port_opts =
      case env do
        [] -> port_opts
        envs -> [{:env, envs} | port_opts]
      end

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)

    collect_turn(session_id, port, "")
  end

  defp shell_escape(arg) when is_binary(arg) do
    # Single-quote the argument and escape any embedded single quotes.
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp shell_escape(arg) when is_list(arg), do: shell_escape(List.to_string(arg))
  defp shell_escape(arg), do: shell_escape(to_string(arg))

  defp collect_turn(session_id, port, buffer) do
    receive do
      {^port, {:data, chunk}} ->
        collect_turn(session_id, port, buffer <> chunk)

      {^port, {:exit_status, _status}} ->
        finalize(session_id, buffer)

      _ ->
        collect_turn(session_id, port, buffer)
    after
      @turn_timeout_ms ->
        try do
          Port.close(port)
        rescue
          _ -> :ok
        end

        {:error, :timeout}
    end
  end

  defp finalize(session_id, buffer) do
    case parse_stream(buffer) do
      {:message, message} ->
        {:ok,
         %{
           content: message["content"] || "",
           tool_calls: message["tool_calls"] || [],
           usage: message["usage"] || %{},
           stop_reason: message["stop_reason"] || "end_turn",
           metadata: %{
             session_id: session_id,
             thread_id: message["thread_id"],
             protocol: :codex
           }
         }}

      :partial ->
        # Process exited but no terminal event was parsed — treat whatever
        # text we collected as the answer rather than bailing out.
        {:ok,
         %{
           content: best_effort_text(buffer),
           tool_calls: [],
           usage: %{},
           stop_reason: "end_turn",
           metadata: %{session_id: session_id, protocol: :codex}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_message(events) do
    text =
      events
      |> Enum.flat_map(fn
        %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => t}}
        when is_binary(t) ->
          [t]

        _ ->
          []
      end)
      |> Enum.join("\n")

    usage =
      Enum.find_value(events, fn
        %{"type" => "turn.completed", "usage" => u} -> u
        _ -> nil
      end) || %{}

    thread_id =
      Enum.find_value(events, fn
        %{"type" => "thread.started", "thread_id" => id} -> id
        _ -> nil
      end)

    {:message,
     %{
       "content" => text,
       "usage" => normalize_usage(usage),
       "stop_reason" => "end_turn",
       "thread_id" => thread_id
     }}
  end

  defp normalize_usage(%{} = usage) do
    %{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      cache_read: usage["cached_input_tokens"],
      cache_write: usage["cache_creation_input_tokens"]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp best_effort_text(buffer) do
    buffer
    |> decode_lines()
    |> Enum.flat_map(fn
      %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => t}}
      when is_binary(t) ->
        [t]

      _ ->
        []
    end)
    |> Enum.join("\n")
  end

  defp decode_lines(buffer) do
    buffer
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      line = String.trim(line)

      if line == "" do
        []
      else
        case Jason.decode(line) do
          {:ok, json} -> [json]
          _ -> []
        end
      end
    end)
  end

  # --- Session state ---

  defp generate_session_id do
    16
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map_join(&Integer.to_string(&1, 16))
  end

  defp fetch_config!(session_id) do
    case :persistent_term.get({__MODULE__, session_id}, nil) do
      nil -> raise "Codex session not found: #{session_id}"
      config -> config
    end
  end
end
