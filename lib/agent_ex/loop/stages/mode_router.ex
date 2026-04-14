defmodule AgentEx.Loop.Stages.ModeRouter do
  @moduledoc """
  Mode-aware routing stage. Replaces StopReasonRouter.

  Routes based on the triple `(mode, phase, stop_reason)` to decide what to do
  with the LLM response. All phase transitions go through `Phase.transition/2`.

  ## Routing Table

  | Mode              | Phase     | Stop Reason | Action                                        |
  |-------------------|-----------|-------------|-----------------------------------------------|
  | :agentic          | :execute  | end_turn    | Accumulate text → next (CommitmentGate)       |
  | :agentic          | :execute  | tool_use    | Store pending_tool_calls → next (ToolExecutor)|
  | :agentic_planned  | :plan     | end_turn    | Parse plan → transition to :execute → reentry |
  | :agentic_planned  | :execute  | end_turn    | Accumulate text → next (CommitmentGate)       |
  | :agentic_planned  | :execute  | tool_use    | Store pending_tool_calls → next (ToolExecutor)|
  | :agentic_planned  | :verify   | end_turn    | Accumulate verification result → done         |
  | :turn_by_turn     | :review   | end_turn    | Build proposal → next (HumanCheckpoint)       |
  | :turn_by_turn     | :review   | tool_use    | Store pending_tool_calls → next (ToolExecutor)|
  | :turn_by_turn     | :execute  | end_turn    | Transition to :review → reentry               |
  | :turn_by_turn     | :execute  | tool_use    | Store pending_tool_calls → next (ToolExecutor)|
  | :conversational   | :execute  | end_turn    | Accumulate text → done                        |
  | any               | any       | max_tokens  | Return what we have → done                    |

  ## Callbacks

  Optional callbacks on `ctx.callbacks`:
  - `:on_response_facts` - `(ctx, text) -> :ok`
  - `:on_persist_turn` - `(ctx, text) -> :ok`
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context
  alias AgentEx.Loop.Helpers
  alias AgentEx.Loop.Phase
  alias AgentEx.Telemetry

  require Logger

  @impl true
  def call(%Context{} = ctx, next) do
    response = ctx.last_response || %AgentEx.LLM.Response{}
    stop_reason = response.stop_reason
    content = response.content

    route(ctx, next, stop_reason, content)
  end

  # --- max_tokens: always return what we have ---
  defp route(ctx, _next, :max_tokens, content) do
    Logger.warning("ModeRouter: max_tokens hit for #{ctx.session_id}")
    text = Helpers.extract_text(content)
    ctx = %{ctx | accumulated_text: Helpers.join_text(ctx.accumulated_text, text)}
    emit_route_event(ctx, :max_tokens, "done")
    emit_turn_event(ctx, :max_tokens)
    {:done, Helpers.result_from_context(ctx)}
  end

  defp route(%Context{mode: :conversational} = ctx, _next, :end_turn, content) do
    text = Helpers.extract_text(content)
    maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)
    ctx = %{ctx | accumulated_text: Helpers.join_text(ctx.accumulated_text, text)}
    emit_route_event(ctx, "end_turn", "done")
    emit_turn_event(ctx, :end_turn)
    {:done, Helpers.result_from_context(ctx)}
  end

  # --- :agentic, :execute, end_turn ---
  defp route(%Context{mode: :agentic, phase: :execute} = ctx, next, :end_turn, content) do
    handle_agentic_end_turn(ctx, next, content)
  end

  # --- :agentic, :execute, tool_use ---
  defp route(%Context{mode: :agentic, phase: :execute} = ctx, next, :tool_use, content) do
    handle_tool_use(ctx, next, content)
  end

  # --- :agentic_planned, :plan, end_turn ---
  defp route(%Context{mode: :agentic_planned, phase: :plan} = ctx, next, :end_turn, content) do
    text = Helpers.extract_text(content)
    maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)

    plan = parse_plan(text)
    ctx = %{ctx | plan: plan}

    Telemetry.event([:plan, :created], %{step_count: length(plan[:steps] || [])}, %{
      session_id: ctx.session_id
    })

    ctx =
      if cb = ctx.callbacks[:on_plan_created] do
        case cb.(plan, ctx) do
          {:ok, ctx} -> ctx
          {:revise, _feedback, ctx} -> ctx
        end
      else
        ctx
      end

    ctx = Phase.transition!(ctx, :execute)
    emit_route_event(ctx, "end_turn", "reentry")
    reentry_or_next(ctx, next)
  end

  defp route(%Context{mode: :agentic_planned, phase: :execute} = ctx, next, :end_turn, content) do
    emit_route_event(ctx, :end_turn, "next")
    handle_agentic_end_turn(ctx, next, content)
  end

  defp route(%Context{mode: :agentic_planned, phase: :execute} = ctx, next, :tool_use, content) do
    emit_route_event(ctx, :tool_use, "next")
    handle_tool_use(ctx, next, content)
  end

  defp route(%Context{mode: :agentic_planned, phase: :verify} = ctx, _next, :end_turn, content) do
    text = Helpers.extract_text(content)
    ctx = %{ctx | accumulated_text: Helpers.join_text(ctx.accumulated_text, text)}
    emit_route_event(ctx, :end_turn, "done")
    emit_turn_event(ctx, :end_turn)
    {:done, Helpers.result_from_context(ctx)}
  end

  defp route(%Context{mode: :turn_by_turn, phase: :review} = ctx, next, :end_turn, content) do
    text = Helpers.extract_text(content)
    maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)
    ctx = %{ctx | accumulated_text: Helpers.join_text(ctx.accumulated_text, text)}
    emit_route_event(ctx, :end_turn, "next")
    next.(ctx)
  end

  defp route(%Context{mode: :turn_by_turn, phase: :review} = ctx, next, :tool_use, content) do
    emit_route_event(ctx, :tool_use, "next")
    handle_tool_use(ctx, next, content)
  end

  defp route(%Context{mode: :turn_by_turn, phase: :execute} = ctx, next, :end_turn, content) do
    text = Helpers.extract_text(content)
    maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)

    ctx = %{ctx | accumulated_text: Helpers.join_text(ctx.accumulated_text, text)}

    case Phase.transition(ctx, :review) do
      {:ok, ctx} ->
        emit_route_event(ctx, :end_turn, "reentry")
        reentry_or_next(ctx, next)

      {:error, _} ->
        emit_route_event(ctx, :end_turn, "done")
        emit_turn_event(ctx, :end_turn)
        {:done, Helpers.result_from_context(ctx)}
    end
  end

  defp route(%Context{mode: :turn_by_turn, phase: :execute} = ctx, next, :tool_use, content) do
    emit_route_event(ctx, :tool_use, "next")
    handle_tool_use(ctx, next, content)
  end

  defp route(ctx, _next, _stop_reason, content) do
    text = Helpers.extract_text(content)
    ctx = %{ctx | accumulated_text: Helpers.join_text(ctx.accumulated_text, text)}
    emit_route_event(ctx, :unknown, "done")
    emit_turn_event(ctx, :unknown)
    {:done, Helpers.result_from_context(ctx)}
  end

  # --- Shared handlers ---

  defp handle_agentic_end_turn(ctx, next, content) do
    text = Helpers.extract_text(content)
    maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)

    if text == "" and ctx.accumulated_text == "" and ctx.turns_used > 0 and
         not ctx.summary_nudge_sent do
      Logger.debug("ModeRouter: tool-only turn with no text, nudging for summary")

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

      reentry_or_next(ctx, next)
    else
      ctx = %{ctx | accumulated_text: Helpers.join_text(ctx.accumulated_text, text)}
      maybe_run_callback(ctx.callbacks[:on_persist_turn], ctx, text)
      next.(ctx)
    end
  end

  defp handle_tool_use(ctx, next, content) do
    text = Helpers.extract_text(content)
    maybe_run_callback(ctx.callbacks[:on_response_facts], ctx, text)

    tool_calls = Helpers.extract_tool_calls(content)
    tool_names = Enum.map(tool_calls, & &1.name)
    assistant_msg = %{"role" => "assistant", "content" => content}

    ctx = %{ctx | messages: ctx.messages ++ [assistant_msg]}

    if text != "" do
      Logger.info(
        "AgentReasoning: #{String.slice(text, 0, 500)} -> tools: #{inspect(tool_names)}"
      )

      workspace_id = ctx.metadata[:workspace_id]
      Context.emit_event(ctx, {:agent_reasoning, text, tool_names, workspace_id})
    end

    workspace_id = ctx.metadata[:workspace_id]
    Context.emit_event(ctx, {:turn_intermediate, tool_names, workspace_id})

    ctx = %{ctx | pending_tool_calls: tool_calls}

    if ctx.turns_used >= ctx.config.max_turns do
      Logger.warning(
        "ModeRouter: max_turns (#{ctx.config.max_turns}) reached for #{ctx.session_id}"
      )

      emit_turn_event(ctx, :max_turns)
      {:done, Helpers.result_from_context(ctx)}
    else
      next.(ctx)
    end
  end

  # --- Plan parsing ---

  defp parse_plan(text) when is_binary(text) and text != "" do
    case extract_json(text) do
      {:ok, %{"steps" => steps}} when is_list(steps) ->
        %{
          steps:
            Enum.map(steps, fn step ->
              %{
                index: step["index"] || 0,
                description: step["description"] || "",
                tools: step["tools"] || [],
                verification: step["verification"] || "",
                status: :pending
              }
            end)
        }

      _ ->
        parse_plan_heuristic(text)
    end
  end

  defp parse_plan(_), do: nil

  defp extract_json(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [match] -> Jason.decode(match)
      _ -> :no_match
    end
  end

  defp parse_plan_heuristic(text) do
    lines = String.split(text, "\n")

    steps =
      lines
      |> Enum.filter(&Regex.match?(~r/^\s*(?:Step\s*\d+|^\d+[\.\)])/, &1))
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        %{
          index: idx,
          description: String.trim(line),
          tools: [],
          verification: "",
          status: :pending
        }
      end)

    if steps != [], do: %{steps: steps}, else: nil
  end

  # --- Helpers ---

  defp reentry_or_next(ctx, next) do
    if ctx.reentry_pipeline do
      ctx.reentry_pipeline.(ctx)
    else
      next.(ctx)
    end
  end

  defp emit_route_event(ctx, stop_reason, action) do
    Telemetry.event([:mode_router, :route], %{}, %{
      session_id: ctx.session_id,
      mode: ctx.mode,
      phase: ctx.phase,
      stop_reason: stop_reason,
      action: action,
      strategy: ctx.strategy
    })
  end

  defp maybe_run_callback(nil, _ctx, _text), do: :ok
  defp maybe_run_callback(_cb, _ctx, ""), do: :ok
  defp maybe_run_callback(cb, ctx, text) when is_function(cb, 2), do: cb.(ctx, text)
  defp maybe_run_callback(_, _, _), do: :ok

  defp emit_turn_event(ctx, stop_reason) do
    Telemetry.event([:orchestration, :turn], %{}, %{
      session_id: ctx.session_id,
      strategy: ctx.strategy,
      mode: ctx.mode,
      phase: ctx.phase,
      stop_reason: stop_reason
    })
  end
end
