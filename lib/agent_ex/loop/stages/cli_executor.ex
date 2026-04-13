defmodule AgentEx.Loop.Stages.CLIExecutor do
  @moduledoc """
  Executes agent prompts via CLI-based local agent protocol.

  Handles session lifecycle (start/resume/stop), streaming response parsing,
  and protocol-specific cost estimation.

  This stage replaces LLMCall for local agent profiles (claude_code, opencode).
  """

  alias AgentEx.Protocol.Registry

  @behaviour AgentEx.Loop.Stage

  @impl true
  def call(ctx, next) do
    protocol = resolve_protocol(ctx)

    # Ensure session is started or resumed
    ctx = ensure_session(ctx, protocol)

    # Get profile config for CLI settings
    profile_config = AgentEx.Loop.Profile.config(ctx.profile || :agentic)

    # Format messages for the CLI protocol
    messages = format_messages_for_cli(ctx, profile_config)

    # Send messages and get response
    case send_to_protocol(protocol, ctx, messages, profile_config) do
      {:ok, response} ->
        # Update context with response
        ctx = update_context_with_response(ctx, response, protocol, profile_config)

        # Stream completion event if callback present
        stream_completion(ctx, response)

        # Continue pipeline
        next.(ctx)

      {:error, reason} ->
        {:error, {:cli_executor, reason}}
    end
  end

  def describe, do: "CLIExecutor"

  @impl true
  def model_tier, do: :default

  # --- Protocol resolution ---

  defp resolve_protocol(ctx) do
    # First check context, then fall back to profile config
    if ctx.protocol_module do
      ctx.protocol_module
    else
      profile = ctx.profile || :agentic
      profile_config = AgentEx.Loop.Profile.config(profile)
      protocol_name = profile_config[:protocol] || :llm

      case Registry.lookup(protocol_name) do
        {:ok, module} -> module
        _ -> raise "Protocol '#{protocol_name}' not registered"
      end
    end
  end

  # --- Session management ---

  defp ensure_session(ctx, protocol) do
    profile = ctx.profile || :agentic
    profile_config = AgentEx.Loop.Profile.config(profile)

    # If we already have a protocol session, we're good
    if ctx.protocol_session_id do
      ctx
    else
      # Start new session
      backend_config =
        Map.merge(
          profile_config[:cli_config] || %{},
          ctx.backend_config || %{}
        )

      case protocol.start(backend_config, ctx) do
        {:ok, session_id} ->
          %{
            ctx
            | protocol_session_id: session_id,
              protocol_module: protocol,
              transport_type: :local_agent,
              backend_config: backend_config
          }

        {:error, reason} ->
          raise "Failed to start CLI session: #{inspect(reason)}"
      end
    end
  end

  # --- Message formatting ---

  defp format_messages_for_cli(ctx, profile_config) do
    # Extract system prompt if present
    system_prompt =
      case ctx.messages do
        [%{"role" => "system", "content" => content} | rest] -> {content, rest}
        _ -> {nil, ctx.messages}
      end

    {system, messages} = system_prompt

    # Format user/assistant messages
    formatted =
      Enum.map(messages, fn %{"role" => role, "content" => content} ->
        # Map internal roles to protocol roles
        wire_role =
          case role do
            "internal" -> "user"
            r when r in ["user", "assistant", "system"] -> r
            _ -> "user"
          end

        %{"role" => wire_role, "content" => content || ""}
      end)

    # Add system prompt if configured
    cli_config = profile_config[:cli_config] || %{}
    system_mode = cli_config[:system_prompt_mode] || :append

    cond do
      system && system_mode == :replace ->
        [{"system", system} | formatted]

      system && system_mode == :append ->
        formatted

      true ->
        formatted
    end
  end

  # --- Protocol communication ---

  defp send_to_protocol(protocol, ctx, messages, _profile_config) do
    if ctx.protocol_session_id && ctx.protocol_session_id != "" do
      # Resume existing session
      protocol.resume(ctx.protocol_session_id, messages, ctx)
    else
      # Send in current session
      protocol.send(ctx.protocol_session_id, messages, ctx)
    end
  end

  # --- Context updates ---

  defp update_context_with_response(ctx, response, _protocol, profile_config) do
    # Extract response components
    content = response[:content] || ""
    tool_calls = response[:tool_calls] || []
    usage = response[:usage] || %{}
    metadata = response[:metadata] || %{}

    # Estimate cost based on profile (for subscription agents)
    cost = estimate_cli_cost(profile_config, metadata)

    # Build response map similar to LLM response format
    response_map = %AgentEx.LLM.Response{
      content: format_cli_content(content),
      stop_reason: metadata[:stop_reason] || :end_turn,
      usage: %{
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        cache_read: 0,
        cache_write: 0
      },
      cost: cost
    }

    %{
      ctx
      | last_response: response_map,
        pending_tool_calls: tool_calls,
        accumulated_text: ctx.accumulated_text <> content,
        total_cost: ctx.total_cost + cost,
        total_tokens:
          ctx.total_tokens + (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
    }
  end

  defp format_cli_content(content) when is_binary(content) do
    [%{type: :text, text: content}]
  end

  defp format_cli_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: :text, text: text}

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        %{type: :tool_use, id: id, name: name, input: input}

      %{type: :text, text: text} ->
        %{type: :text, text: text}

      %{type: :tool_use, id: id, name: name, input: input} ->
        %{type: :tool_use, id: id, name: name, input: input}

      other ->
        other
    end)
  end

  defp format_cli_content(_), do: []

  # --- Cost estimation for subscription agents ---

  defp estimate_cli_cost(profile_config, metadata) do
    # CLI agents typically don't have per-token pricing
    # Instead, we can estimate based on session time or fixed rates
    # For now, return 0 - the frontend will track session limits instead

    # Future: could track based on metadata[:duration_ms] or similar
    _ = profile_config
    _ = metadata
    0.0
  end

  # --- Streaming ---

  defp stream_completion(ctx, response) do
    if callback = ctx.callbacks[:on_protocol_complete] do
      callback.(response, ctx)
    end
  end
end
