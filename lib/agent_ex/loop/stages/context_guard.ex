defmodule AgentEx.Loop.Stages.ContextGuard do
  @moduledoc """
  Checks context window usage and triggers compaction if needed.

  Runs before LLMCall. Estimates the current context size from messages and
  tool schemas. When usage exceeds the configured threshold (default 80%),
  compacts older messages by summarizing them with a deterministic summary,
  then replaces them with a compact handoff message.

  Also enforces a per-session cost limit as a safety rail.
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context

  require Logger

  # Conservative chars-per-token estimate
  @chars_per_token 3.5

  # Default context window if not resolvable (128k tokens)
  @default_context_window 128_000

  # Fallback cost limit if not set in config
  @default_cost_limit_usd 5.0

  # Minimum messages to keep before compaction (system + last few exchanges)
  @min_messages_to_keep 6

  @impl true
  def call(%Context{} = ctx, next) do
    cost_limit = ctx.config[:session_cost_limit_usd] || @default_cost_limit_usd

    cond do
      ctx.total_cost >= cost_limit ->
        Logger.warning(
          "ContextGuard: session #{ctx.session_id} hit cost limit ($#{Float.round(ctx.total_cost, 4)} >= $#{cost_limit})"
        )

        {:done, result_with_cost_warning(ctx)}

      should_compact?(ctx) ->
        Logger.info(
          "ContextGuard: compacting context for #{ctx.session_id} (#{round(estimate_usage(ctx) * 100)}% used)"
        )

        ctx = compact_messages(ctx)
        next.(ctx)

      true ->
        ctx = %{ctx | context_pct: estimate_usage(ctx)}
        next.(ctx)
    end
  end

  defp should_compact?(ctx) do
    threshold = ctx.config[:compaction_at_pct] || 0.80
    usage = estimate_usage(ctx)
    usage >= threshold and length(ctx.messages) > @min_messages_to_keep
  end

  defp estimate_usage(ctx) do
    context_window = resolve_context_window(ctx)
    message_tokens = estimate_message_tokens(ctx.messages)
    tool_tokens = estimate_tool_tokens(ctx.tools)
    total = message_tokens + tool_tokens
    min(total / context_window, 1.0)
  end

  defp resolve_context_window(ctx) do
    case ctx.config[:context_window] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_context_window
    end
  end

  defp estimate_message_tokens(messages) do
    messages
    |> Enum.map(fn msg ->
      content = msg["content"]

      chars =
        cond do
          is_binary(content) ->
            String.length(content)

          is_list(content) ->
            Enum.reduce(content, 0, fn block, acc ->
              acc + String.length(block["text"] || block["content"] || inspect(block))
            end)

          true ->
            0
        end

      # Per-message overhead (~4 tokens for role, delimiters)
      round(chars / @chars_per_token) + 4
    end)
    |> Enum.sum()
  end

  defp estimate_tool_tokens(tools) do
    Enum.reduce(tools, 0, fn tool, acc ->
      name_len = String.length(tool["name"] || "")
      desc_len = String.length(tool["description"] || "")

      schema_len =
        case Jason.encode(tool["input_schema"] || %{}) do
          {:ok, json} -> byte_size(json)
          _ -> 0
        end

      acc + round((name_len + desc_len + schema_len + 40) / @chars_per_token)
    end)
  end

  defp compact_messages(ctx) do
    messages = ctx.messages
    total = length(messages)

    keep_recent = min(@min_messages_to_keep, total - 1)
    {head, recent} = Enum.split(messages, total - keep_recent)

    case head do
      [system_msg | older] when older != [] ->
        summary = summarize_messages(older)

        handoff_msg = %{
          "role" => "user",
          "content" =>
            "[System: Earlier conversation was compacted to save context. Summary of what happened:\n\n" <>
              summary <> "\n\nContinue from where you left off.]"
        }

        compacted = [system_msg, handoff_msg | recent]

        Logger.info(
          "ContextGuard: compacted #{length(older)} messages into handoff summary for #{ctx.session_id}"
        )

        %{ctx | messages: compacted, context_pct: estimate_usage(%{ctx | messages: compacted})}

      _ ->
        %{ctx | context_pct: estimate_usage(ctx)}
    end
  end

  defp summarize_messages(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case msg["role"] do
        "assistant" ->
          text = extract_text(msg["content"])
          tools = extract_tool_names(msg["content"])

          cond do
            tools != [] ->
              ["Used tools: #{Enum.join(tools, ", ")}" | acc]

            text != "" ->
              summary = String.slice(text, 0, 200)
              truncated = if String.length(text) > 200, do: "...", else: ""
              ["Agent: #{summary}#{truncated}" | acc]

            true ->
              acc
          end

        "user" ->
          text = extract_text(msg["content"])

          if text != "" and not String.starts_with?(text, "[System") do
            summary = String.slice(text, 0, 150)
            truncated = if String.length(text) > 150, do: "...", else: ""
            ["User: #{summary}#{truncated}" | acc]
          else
            acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.take(20)
    |> Enum.join("\n")
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp extract_text(_), do: ""

  defp extract_tool_names(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(&(&1["name"] || "unknown"))
  end

  defp extract_tool_names(_), do: []

  defp result_with_cost_warning(ctx) do
    warning =
      "I've reached the per-session cost limit ($#{Float.round(ctx.total_cost, 2)}). " <>
        "This is a safety measure to prevent runaway costs. " <>
        "Please start a new conversation to continue, or ask an admin to adjust the limit."

    text =
      if ctx.accumulated_text == "",
        do: warning,
        else: ctx.accumulated_text <> "\n\n" <> warning

    %{
      text: text,
      cost: ctx.total_cost,
      tokens: ctx.total_tokens,
      steps: ctx.turns_used
    }
  end
end
