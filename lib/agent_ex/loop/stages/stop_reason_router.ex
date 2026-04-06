defmodule AgentEx.Loop.Stages.StopReasonRouter do
  @moduledoc """
  Routes based on the LLM response's stop_reason.

  This is the core loop mechanic -- not a step counter. The LLM itself decides
  the termination condition via stop_reason:

  - `end_turn` -> Extract text, mark done
  - `tool_use` -> Pass to ToolExecutor, then loop back to LLMCall
  - `max_tokens` -> Context exhausted, return what we have
  - Other -> Treat as end_turn

  ## Callbacks

  Optional callbacks on `ctx.callbacks`:
  - `:on_response_facts` - `(ctx, text) -> :ok` — called with response text for fact extraction
  - `:on_persist_turn` - `(ctx, text) -> :ok` — called to persist qualifying turns
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context

  require Logger

  @impl true
  def call(%Context{} = ctx, next) do
    response = ctx.last_response || %{}
    stop_reason = response["stop_reason"]
    content = response["content"]

    case stop_reason do
      "end_turn" ->
        text = extract_text(content)
        maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)

        # When tools ran but the LLM produced no text for the user, nudge it
        if text == "" and ctx.accumulated_text == "" and ctx.turns_used > 0 and
             not ctx.summary_nudge_sent do
          Logger.debug("StopReasonRouter: tool-only turn with no text, nudging for summary")

          nudge = %{
            "role" => "user",
            "content" =>
              "[System: You used tools but produced no response for the user. " <>
                "Briefly tell the user what you did and what the outcome was. " <>
                "If something failed, explain what went wrong and suggest next steps.]"
          }

          assistant_msg = %{"role" => "assistant", "content" => content}

          ctx = %{
            ctx
            | messages: ctx.messages ++ [assistant_msg, nudge],
              summary_nudge_sent: true
          }

          if ctx.reentry_pipeline do
            ctx.reentry_pipeline.(ctx)
          else
            next.(ctx)
          end
        else
          ctx = %{ctx | accumulated_text: join_text(ctx.accumulated_text, text)}
          maybe_run_callback(ctx.callbacks[:on_persist_turn], ctx, text)
          next.(ctx)
        end

      "tool_use" ->
        text = extract_text(content)
        maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)

        tool_calls = extract_tool_calls(content)
        tool_names = Enum.map(tool_calls, & &1["name"])
        assistant_msg = %{"role" => "assistant", "content" => content}

        ctx = %{ctx | messages: ctx.messages ++ [assistant_msg]}

        # Broadcast agent reasoning trace
        if text != "" do
          Logger.info(
            "AgentReasoning: #{String.slice(text, 0, 500)} -> tools: #{inspect(tool_names)}"
          )

          workspace_id = ctx.metadata[:workspace_id]
          Context.emit_event(ctx, {:agent_reasoning, text, tool_names, workspace_id})
        end

        # Signal the UI to clear streaming text and show working progress
        workspace_id = ctx.metadata[:workspace_id]
        Context.emit_event(ctx, {:turn_intermediate, tool_names, workspace_id})

        # Store tool_calls for ToolExecutor stage
        ctx = %{ctx | pending_tool_calls: tool_calls}

        # Check safety rail
        if ctx.turns_used >= ctx.config.max_turns do
          Logger.warning(
            "StopReasonRouter: max_turns (#{ctx.config.max_turns}) reached for #{ctx.session_id}"
          )

          {:done, result_from_context(ctx)}
        else
          next.(ctx)
        end

      "max_tokens" ->
        Logger.warning("StopReasonRouter: max_tokens hit for #{ctx.session_id}")
        text = extract_text(content)
        ctx = %{ctx | accumulated_text: join_text(ctx.accumulated_text, text)}
        {:done, result_from_context(ctx)}

      _other ->
        text = extract_text(content)
        ctx = %{ctx | accumulated_text: join_text(ctx.accumulated_text, text)}
        {:done, result_from_context(ctx)}
    end
  end

  defp result_from_context(ctx) do
    %{
      text: ctx.accumulated_text,
      cost: ctx.total_cost,
      tokens: ctx.total_tokens,
      steps: ctx.turns_used
    }
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp extract_text(_), do: ""

  defp extract_tool_calls(content) when is_list(content) do
    Enum.filter(content, &(&1["type"] == "tool_use"))
  end

  defp extract_tool_calls(_), do: []

  defp join_text("", text), do: text
  defp join_text(acc, ""), do: acc
  defp join_text(acc, text), do: acc <> "\n\n" <> text

  defp maybe_run_callback(nil, _ctx, _text), do: :ok
  defp maybe_run_callback(_cb, _ctx, ""), do: :ok
  defp maybe_run_callback(cb, ctx, text) when is_function(cb, 2), do: cb.(ctx, text)
  defp maybe_run_callback(_, _, _), do: :ok
end
