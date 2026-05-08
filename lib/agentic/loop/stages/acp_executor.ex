defmodule Agentic.Loop.Stages.ACPExecutor do
  @moduledoc """
  Executes agent prompts via ACP (Agent Client Protocol).

  Handles ACP session lifecycle (connect/prompt/cancel/close), streaming
  response parsing, and protocol-specific cost estimation.

  This stage replaces LLMCall for ACP-based agent profiles.
  """

  @behaviour Agentic.Loop.Stage

  alias Agentic.Loop.Profile
  alias Agentic.Protocol.Registry

  @impl true
  def call(ctx, next) do
    protocol = resolve_protocol(ctx)

    ctx = ensure_session(ctx, protocol)

    profile_config = Profile.config(ctx.profile || :agentic)

    messages = format_messages_for_acp(ctx)

    case send_to_protocol(protocol, ctx, messages) do
      {:ok, response} ->
        ctx = update_context_with_response(ctx, response, profile_config)

        stream_completion(ctx, response)

        next.(ctx)

      {:error, reason} ->
        {:error, {:acp_executor, reason}}
    end
  end

  def describe, do: "ACPExecutor"

  @impl true
  def model_tier, do: :default

  # --- Protocol resolution ---

  defp resolve_protocol(ctx) do
    if ctx.protocol_module do
      ctx.protocol_module
    else
      profile = ctx.profile || :agentic
      profile_config = Profile.config(profile)
      protocol_name = profile_config[:protocol] || :llm

      case Registry.lookup(protocol_name) do
        {:ok, module} -> module
        _ -> raise "Protocol '#{protocol_name}' not registered"
      end
    end
  end

  # --- Session management ---

  defp ensure_session(ctx, protocol) do
    if ctx.protocol_session_id do
      ctx
    else
      # Mount AgentFS overlay before starting the session
      {overlay_path, ctx} =
        case Agentic.AgentFS.mount(ctx) do
          :noop -> {nil, ctx}
          {path, updated_ctx} -> {path, updated_ctx}
        end

      backend_config =
        ctx.backend_config
        |> Map.put_new(:workspace, get_workspace(ctx))
        |> Map.put(
          :callbacks,
          ctx.callbacks
        )

      case protocol.start(backend_config, ctx) do
        {:ok, session_id} ->
          %{
            ctx
            | protocol_session_id: session_id,
              protocol_module: protocol,
              transport_type: :acp,
              backend_config: backend_config
          }

        {:error, reason} ->
          # Unmount on failure
          if overlay_path, do: Agentic.AgentFS.unmount(ctx), else: :ok
          raise "Failed to start ACP session: #{inspect(reason)}"
      end
    end
  end

  defp get_workspace(ctx) do
    ctx.metadata[:workspace] || ctx.metadata[:workspace_path] || File.cwd!()
  end

  # --- Message formatting ---

  defp format_messages_for_acp(ctx) do
    Enum.reject(ctx.messages, fn
      %{"role" => "system"} -> true
      _ -> false
    end)
  end

  # --- Protocol communication ---

  defp send_to_protocol(protocol, ctx, messages) do
    protocol.send(ctx.protocol_session_id, messages, ctx)
  end

  # --- Context updates ---

  defp update_context_with_response(ctx, response, profile_config) do
    content = response[:content] || ""
    tool_calls = response[:tool_calls] || []
    metadata = response[:metadata] || %{}

    cost = estimate_acp_cost(profile_config, metadata)

    response_map = %Agentic.LLM.Response{
      content: format_acp_content(content),
      stop_reason: metadata[:stop_reason] || :end_turn,
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        cache_read: 0,
        cache_write: 0
      },
      cost: cost
    }

    %{
      ctx
      | last_response: response_map,
        pending_tool_calls: tool_calls,
        total_cost: ctx.total_cost + cost
    }
  end

  defp format_acp_content(content) when is_binary(content) do
    [%{type: :text, text: content}]
  end

  defp format_acp_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: :text, text: text}

      %{type: :text, text: text} ->
        %{type: :text, text: text}

      other ->
        other
    end)
  end

  defp format_acp_content(_), do: []

  defp estimate_acp_cost(_profile_config, _metadata) do
    0.0
  end

  defp stream_completion(ctx, response) do
    if callback = ctx.callbacks[:on_protocol_complete] do
      callback.(response, ctx)
    end
  end
end
