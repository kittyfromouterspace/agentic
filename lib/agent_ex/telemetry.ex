defmodule AgentEx.Telemetry do
  @moduledoc """
  Centralized telemetry helpers for AgentEx.

  All telemetry in AgentEx goes through this module so event names,
  measurements, and metadata are consistent. The canonical prefix is
  `[:agent_ex]`.

  ## Event Catalogue

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:agent_ex, :session, :start]` | — | session_id, mode, profile |
  | `[:agent_ex, :session, :stop]` | duration, cost, tokens, steps | session_id, mode |
  | `[:agent_ex, :session, :error]` | duration | session_id, mode, error |
  | `[:agent_ex, :session, :resume]` | — | session_id, turns_restored |
  | `[:agent_ex, :pipeline, :stage, :start]` | — | session_id, stage |
  | `[:agent_ex, :pipeline, :stage, :stop]` | duration | session_id, stage |
  | `[:agent_ex, :llm_call, :start]` | — | session_id, model_tier, model_selection_mode |
  | `[:agent_ex, :llm_call, :stop]` | duration, input_tokens, output_tokens, cost_usd | session_id, model_tier, model_selection_mode, route, provider |
  | `[:agent_ex, :tool, :start]` | — | session_id, tool_name |
  | `[:agent_ex, :tool, :stop]` | duration, output_bytes | session_id, tool_name, success |
  | `[:agent_ex, :context, :compact]` | messages_before, messages_after, pct_before, pct_after | session_id |
  | `[:agent_ex, :context, :cost_limit]` | cost_usd, limit_usd | session_id |
  | `[:agent_ex, :phase, :transition]` | — | session_id, mode, from, to |
  | `[:agent_ex, :mode_router, :route]` | — | session_id, mode, phase, stop_reason, action |
  | `[:agent_ex, :commitment, :detected]` | continuations | session_id |
  | `[:agent_ex, :plan, :created]` | step_count | session_id |
  | `[:agent_ex, :plan, :step, :complete]` | — | session_id, step_index, total_steps |
  | `[:agent_ex, :plan, :all_complete]` | — | session_id, total_steps |
  | `[:agent_ex, :circuit_breaker, :trip]` | failure_count | tool_name |
  | `[:agent_ex, :circuit_breaker, :recover]` | — | tool_name |
  | `[:agent_ex, :model_router, :refresh]` | duration, primary_count, lightweight_count | — |
  | `[:agent_ex, :model_router, :resolve, :start]` | — | session_id, selection_mode |
  | `[:agent_ex, :model_router, :resolve, :stop]` | duration, route_count | session_id, selection_mode, selected_provider, selected_model_id, complexity, preference, error |
  | `[:agent_ex, :model_router, :auto_select]` | — | preference, selected_provider, selected_model_id, complexity, error |
  | `[:agent_ex, :model_router, :auto, :selected]` | — | session_id, complexity, needs_vision, needs_audio, needs_reasoning, needs_large_context, estimated_input_tokens, preference, selected_model, selected_provider |
  | `[:agent_ex, :model_router, :auto, :fallback]` | — | session_id, reason |
  | `[:agent_ex, :model_router, :analysis, :start]` | — | method, session_id, request_length |
  | `[:agent_ex, :model_router, :analysis, :stop]` | duration | method, session_id, complexity, needs_vision, needs_audio, needs_reasoning, needs_large_context, estimated_input_tokens, required_capabilities |
  | `[:agent_ex, :model_router, :analysis, :fallback]` | — | session_id, from, to, reason |
  | `[:agent_ex, :model_router, :analysis, :parse_failure]` | — | — |
  | `[:agent_ex, :model_router, :selection, :start]` | — | session_id, preference, request_length |
  | `[:agent_ex, :model_router, :selection, :stop]` | duration, candidate_count, best_score | session_id, preference, complexity, selected_provider, selected_model_id, selected_label, needs_vision, needs_reasoning, needs_large_context, top3, error |
  | `[:agent_ex, :memory, :ingest]` | fact_count | workspace_id |
  | `[:agent_ex, :memory, :evict]` | evicted_count, remaining_count | workspace_id |
  | `[:agent_ex, :memory, :retrieval, :stop]` | duration, context_chars, cache_hit | workspace_id, incremental |
  | `[:agent_ex, :subagent, :spawn]` | — | session_id, parent_session_id, depth |
  | `[:agent_ex, :subagent, :complete]` | duration, cost, steps | session_id, parent_session_id |
  | `[:agent_ex, :subagent, :error]` | duration | session_id, parent_session_id, error |
  """

  @doc """
  Emit a telemetry event with the standard `[:agent_ex]` prefix.
  """
  @spec event([atom()], map(), map()) :: :ok
  def event(event_suffix, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([:agent_ex | event_suffix], measurements, metadata)
  rescue
    _ -> :ok
  end

  @doc """
  Execute a function wrapped in start/stop telemetry events.
  """
  @spec span([atom()], [atom()], map(), map(), (-> result)) :: result when result: var
  def span(start_suffix, stop_suffix, start_measurements \\ %{}, metadata \\ %{}, fun) do
    start_time = System.monotonic_time()
    event(start_suffix, start_measurements, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      event(stop_suffix, Map.put(start_measurements, :duration, duration), metadata)
      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        event(
          stop_suffix,
          Map.put(start_measurements, :duration, duration),
          Map.put(metadata, :error, true)
        )

        reraise e, __STACKTRACE__
    end
  end
end
