defmodule Agentic.Loop.ContextCompression do
  @moduledoc """
  Two-tier context compression: truncation for moderate overflow, LLM-based
  summarization for severe overflow.

  Ported from Homunculus MemoryManager.optimize_context pattern.

  ## Strategy

  - When context is < 2× budget: truncate older messages (keep recent ones intact)
  - When context is ≥ 2× budget: use LLM summarization via `llm_chat` callback
  - Falls back to truncation on LLM error
  """

  alias Agentic.Loop.Context
  alias Agentic.Loop.Helpers

  @chars_per_token 3.5
  @max_summary_tokens 2000

  @doc "Check if LLM-based summarization is available for this context."
  def available?(ctx) do
    is_function(ctx.callbacks[:llm_chat], 1)
  end

  @doc """
  Compress messages to fit within a token budget.

  Returns `{compressed_messages, was_summarized}`.
  """
  @spec compress([map()], non_neg_integer(), Context.t()) :: {[map()], boolean()}
  def compress(messages, token_budget, ctx) do
    current_tokens = estimate_tokens(messages)

    if current_tokens <= token_budget do
      {messages, false}
    else
      ratio = current_tokens / token_budget

      if ratio >= 2.0 and ctx.callbacks[:llm_chat] do
        summarize(messages, token_budget, ctx)
      else
        {truncate(messages, token_budget), false}
      end
    end
  end

  @doc "Truncate messages to fit within a token budget, keeping system + recent messages."
  @spec truncate([map()], non_neg_integer()) :: [map()]
  def truncate(messages, token_budget) do
    system = Enum.filter(messages, &(&1["role"] == "system"))
    non_system = Enum.reject(messages, &(&1["role"] == "system"))

    system_tokens = estimate_tokens(system)
    remaining_budget = max(token_budget - system_tokens - 100, 0)

    kept = keep_fitting(non_system, remaining_budget)
    system ++ kept
  end

  @doc "Estimate token count for a list of messages."
  @spec estimate_tokens([map()]) :: non_neg_integer()
  def estimate_tokens(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content = msg["content"]
      chars = message_chars(content)
      acc + round(chars / @chars_per_token) + 4
    end)
  end

  defp summarize(messages, token_budget, ctx) do
    system = Enum.filter(messages, &(&1["role"] == "system"))
    non_system = Enum.reject(messages, &(&1["role"] == "system"))

    {to_summarize, to_keep} = split_for_summary(non_system, token_budget)

    if to_summarize == [] do
      {truncate(messages, token_budget), false}
    else
      case call_llm_summary(to_summarize, ctx) do
        {:ok, summary_text} ->
          summary_msg = %{
            "role" => "user",
            "content" =>
              "[System: Earlier conversation was summarized to save context.\n\n#{summary_text}\n\nContinue from where you left off.]"
          }

          compressed = system ++ [summary_msg] ++ to_keep
          {compressed, true}

        {:error, _} ->
          {truncate(messages, token_budget), false}
      end
    end
  end

  defp split_for_summary(messages, token_budget) do
    keep_budget = div(token_budget, 3)
    keep_chars = keep_budget * round(@chars_per_token)

    {to_keep_rev, to_summarize_rev} =
      messages
      |> Enum.reverse()
      |> Enum.split_while(fn msg ->
        msg_chars = message_chars(msg["content"])
        keep_chars = keep_chars - msg_chars
        keep_chars > 0
      end)

    {Enum.reverse(to_summarize_rev), Enum.reverse(to_keep_rev)}
  end

  defp call_llm_summary(messages, ctx) do
    text = messages_to_summary_text(messages)

    params = %{
      "messages" => [
        %{
          "role" => "system",
          "content" =>
            "You are a concise summarizer. Summarize the conversation below in at most #{@max_summary_tokens} tokens. Focus on: what was done, what was found, what remains. Be factual and brief."
        },
        %{"role" => "user", "content" => text}
      ],
      "session_id" => ctx.session_id,
      "model_tier" => "lightweight"
    }

    case ctx.callbacks[:llm_chat].(params) do
      {:ok, %{"content" => content}} ->
        text = extract_text(content)
        if text != "", do: {:ok, text}, else: {:error, :empty_summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp messages_to_summary_text(messages) do
    messages
    |> Enum.map(fn msg ->
      role = msg["role"] |> String.capitalize()
      text = extract_text(msg["content"]) |> String.slice(0, 500)
      "#{role}: #{text}"
    end)
    |> Enum.join("\n\n")
    |> String.slice(0, 20_000)
  end

  defp keep_fitting(messages, token_budget) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, used} ->
      msg_tokens = estimate_tokens([msg])
      new_used = used + msg_tokens

      if new_used <= token_budget do
        {:cont, {[msg | acc], new_used}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
  end

  defp message_chars(content) when is_binary(content), do: String.length(content)

  defp message_chars(content) when is_list(content) do
    Enum.reduce(content, 0, fn block, acc ->
      acc + String.length(block["text"] || block["content"] || "")
    end)
  end

  defp message_chars(_), do: 0

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content), do: Helpers.extract_text(content)

  defp extract_text(_), do: ""
end
