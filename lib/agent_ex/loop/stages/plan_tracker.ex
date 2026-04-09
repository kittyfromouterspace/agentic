defmodule AgentEx.Loop.Stages.PlanTracker do
  @moduledoc """
  Tracks plan step completion for :agentic_planned mode.

  Only active when `ctx.mode == :agentic_planned` and `ctx.phase == :execute`.
  Sits after ToolExecutor in the pipeline.

  Responsibilities:
  - After each LLM response, determine which plan step was just worked on
  - Increment `ctx.plan_step_index` when a step appears complete
  - Inject a progress message into the conversation
  - When all steps are complete, transition to `:verify` phase
  - Call `:on_step_complete` callback if provided
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context
  alias AgentEx.Loop.Phase
  alias AgentEx.Telemetry

  require Logger

  @step_complete_patterns [
    ~r/step\s+\d+\s+(?:is\s+)?(?:complete|done|finished)/i,
    ~r/(?:completed|finished|done with)\s+step\s+\d+/i,
    ~r/✓.*step\s+\d+/i
  ]

  @impl true
  def call(%Context{mode: :agentic_planned, phase: :execute, plan: plan} = ctx, next)
      when plan != nil do
    ctx = track_step_progress(ctx)

    if all_steps_complete?(ctx) do
      Logger.info(
        "PlanTracker: all steps complete for #{ctx.session_id}, transitioning to :verify"
      )

      steps = ctx.plan[:steps] || []

      Telemetry.event([:plan, :all_complete], %{}, %{
        session_id: ctx.session_id,
        total_steps: length(steps)
      })

      case Phase.transition(ctx, :verify) do
        {:ok, ctx} -> next.(ctx)
        {:error, _reason} -> next.(ctx)
      end
    else
      next.(ctx)
    end
  end

  @impl true
  def call(ctx, next), do: next.(ctx)

  defp track_step_progress(ctx) do
    plan = ctx.plan
    steps = plan[:steps] || []
    current_index = ctx.plan_step_index

    if current_index < length(steps) do
      current_step = Enum.at(steps, current_index)

      if step_complete?(ctx) do
        steps =
          List.update_at(steps, current_index, fn step ->
            %{step | status: :complete}
          end)

        ctx = %{
          ctx
          | plan: %{plan | steps: steps},
            plan_step_index: current_index + 1,
            plan_steps_completed: ctx.plan_steps_completed ++ [current_index]
        }

        total_steps = length(steps)

        Telemetry.event([:plan, :step, :complete], %{}, %{
          session_id: ctx.session_id,
          step_index: current_index,
          total_steps: total_steps
        })

        maybe_invoke_step_callback(ctx, current_step)

        ctx = inject_progress_message(ctx)

        ctx
      else
        steps =
          List.update_at(steps, current_index, fn step ->
            if step.status == :pending, do: %{step | status: :in_progress}, else: step
          end)

        %{ctx | plan: %{plan | steps: steps}}
      end
    else
      ctx
    end
  end

  defp step_complete?(ctx) do
    text = ctx.accumulated_text
    tool_calls = ctx.pending_tool_calls

    cond do
      tool_calls != [] ->
        false

      text != "" and Enum.any?(@step_complete_patterns, &Regex.match?(&1, text)) ->
        true

      text != "" and ctx.last_response != nil ->
        stop_reason = ctx.last_response["stop_reason"] || ctx.last_response[:stop_reason]
        stop_reason in ["end_turn", :end_turn] and text != ""

      true ->
        false
    end
  end

  defp all_steps_complete?(ctx) do
    steps = ctx.plan[:steps] || []
    steps != [] and Enum.all?(steps, &(&1.status == :complete))
  end

  defp inject_progress_message(ctx) do
    steps = ctx.plan[:steps] || []
    completed = ctx.plan_steps_completed
    total = length(steps)
    current_idx = ctx.plan_step_index

    next_step_description =
      if current_idx < total do
        "Next step: #{Enum.at(steps, current_idx)[:description]}"
      else
        "All steps complete."
      end

    progress =
      "[System: Plan progress — Step #{length(completed)}/#{total} complete. #{next_step_description}]"

    progress_msg = %{"role" => "user", "content" => progress}
    %{ctx | messages: ctx.messages ++ [progress_msg]}
  end

  defp maybe_invoke_step_callback(ctx, step) do
    if cb = ctx.callbacks[:on_step_complete] do
      result = %{text: ctx.accumulated_text, turns: ctx.turns_used}

      try do
        cb.(step, result, ctx)
      rescue
        _ -> :ok
      end
    end
  end
end
