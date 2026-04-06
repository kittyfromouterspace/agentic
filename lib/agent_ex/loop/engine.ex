defmodule AgentEx.Loop.Engine do
  @moduledoc """
  Composable pipeline engine for agent loops.

  Runs a list of stages as a pipeline. Each stage wraps the next, forming a
  middleware chain.

  ## Usage

      Engine.run(context, [ContextGuard, LLMCall, StopReasonRouter, ToolExecutor])

  ## Stop-reason routing

  The loop doesn't use a step counter. The `StopReasonRouter` stage decides
  whether to loop (tool_use), terminate (end_turn), or compact (max_tokens).
  A hard `max_turns` limit exists only as a safety rail.
  """

  alias AgentEx.Loop.Context

  require Logger

  @doc """
  Run the pipeline with the given stages.

  Returns `{:ok, result_map}` or `{:error, reason}`.
  """
  def run(%Context{} = ctx, stages) when is_list(stages) do
    pipeline = build_pipeline(stages)

    case pipeline.(ctx) do
      {:done, result} -> {:ok, result}
      {:ok, ctx} -> {:ok, result_from_context(ctx)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.error(
        "Loop engine crashed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, Exception.message(e)}
  end

  @doc """
  Build a pipeline function from a list of stage modules.

  The pipeline is built right-to-left: the last stage in the list wraps the
  terminal function, and each preceding stage wraps the one after it.
  """
  def build_pipeline(stages) do
    terminal = fn ctx -> {:done, result_from_context(ctx)} end

    stages
    |> Enum.reverse()
    |> Enum.reduce(terminal, fn stage_mod, next ->
      fn ctx -> stage_mod.call(ctx, next) end
    end)
  end

  defp result_from_context(%Context{} = ctx) do
    %{
      text: ctx.accumulated_text,
      cost: ctx.total_cost,
      tokens: ctx.total_tokens,
      steps: ctx.turns_used
    }
  end
end
