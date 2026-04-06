defmodule AgentEx.Loop.Stages.ProgressInjector do
  @moduledoc """
  Injects a system reminder after tool calls to prevent context drift.

  After every tool use, injects a structured reminder with current phase,
  progress, context usage, and turns remaining. This keeps the model focused
  on its current objective in long conversations.

  Only injects when `config.progress_injection` is `:system_reminder`.
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context

  @impl true
  def call(%Context{} = ctx, next) do
    case ctx.config[:progress_injection] do
      :system_reminder ->
        ctx = inject_reminder(ctx)
        next.(ctx)

      _ ->
        next.(ctx)
    end
  end

  defp inject_reminder(ctx) do
    max_turns = ctx.config[:max_turns] || 50
    remaining = max_turns - ctx.turns_used

    reminder = """
    [SYSTEM REMINDER]
    Phase: #{ctx.phase} | Context: #{round(ctx.context_pct * 100)}%
    Turns: #{ctx.turns_used}/#{max_turns} (#{remaining} remaining)
    Bias to action. Verify before marking done.
    """

    reminder_msg = %{"role" => "user", "content" => [%{"type" => "text", "text" => reminder}]}

    # Only inject if the last message was a tool_result (we just finished tools)
    last_msg = List.last(ctx.messages)

    if last_msg && is_list(last_msg["content"]) &&
         Enum.any?(last_msg["content"], &(&1["type"] == "tool_result")) do
      %{ctx | messages: ctx.messages ++ [reminder_msg]}
    else
      ctx
    end
  end
end
