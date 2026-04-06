defmodule AgentEx.CircuitBreaker do
  @moduledoc """
  Per-tool circuit breaker for agent tool execution.

  Tracks consecutive failures per tool name. After a configurable threshold
  (default 3), the tool is marked as "open" and calls are rejected instantly
  for a cooldown period (default 5 minutes).

  State transitions:
    :closed (normal) -> 3 consecutive failures -> :open (rejecting)
    :open -> cooldown expires -> :half_open (testing)
    :half_open -> success -> :closed
    :half_open -> failure -> :open

  Uses ETS for lock-free reads on the hot path. No GenServer needed.
  """

  require Logger

  @table :agent_ex_circuit_breaker
  @failure_threshold 3
  @cooldown_ms to_timeout(minute: 5)

  @type state :: :closed | :open | :half_open

  @doc "Initialize the ETS table. Call once at app startup."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Check if a tool is available (circuit closed or half-open)."
  @spec check(String.t()) :: :ok | {:error, :circuit_open}
  def check(tool_name) do
    case get_state(tool_name) do
      :closed -> :ok
      :half_open -> :ok
      :open -> {:error, :circuit_open}
    end
  end

  @doc "Record a successful tool execution. Resets failure count."
  @spec record_success(String.t()) :: :ok
  def record_success(tool_name) do
    ensure_table()

    case get_state(tool_name) do
      :half_open ->
        :ets.insert(@table, {tool_name, :closed, 0, 0})
        Logger.info("CircuitBreaker: #{tool_name} recovered (half_open -> closed)")

      _ ->
        :ets.insert(@table, {tool_name, :closed, 0, 0})
    end

    :ok
  end

  @doc "Record a failed tool execution. May trip the circuit."
  @spec record_failure(String.t()) :: :ok
  def record_failure(tool_name) do
    ensure_table()

    case :ets.lookup(@table, tool_name) do
      [{^tool_name, :half_open, _failures, _opened_at}] ->
        opened_at = System.monotonic_time(:millisecond)
        :ets.insert(@table, {tool_name, :open, @failure_threshold, opened_at})

        Logger.warning(
          "CircuitBreaker: #{tool_name} failed during recovery test (half_open -> open)"
        )

      [{^tool_name, :closed, failures, _opened_at}] ->
        new_failures = failures + 1

        if new_failures >= @failure_threshold do
          opened_at = System.monotonic_time(:millisecond)
          :ets.insert(@table, {tool_name, :open, new_failures, opened_at})

          Logger.warning(
            "CircuitBreaker: #{tool_name} tripped after #{new_failures} failures (closed -> open)"
          )
        else
          :ets.insert(@table, {tool_name, :closed, new_failures, 0})
        end

      _ ->
        :ets.insert(@table, {tool_name, :closed, 1, 0})
    end

    :ok
  end

  @doc "Get the current state of a tool's circuit breaker."
  @spec get_state(String.t()) :: state()
  def get_state(tool_name) do
    ensure_table()

    case :ets.lookup(@table, tool_name) do
      [{^tool_name, :open, _failures, opened_at}] ->
        now = System.monotonic_time(:millisecond)

        if now - opened_at >= @cooldown_ms do
          :ets.insert(@table, {tool_name, :half_open, 0, opened_at})
          :half_open
        else
          :open
        end

      [{^tool_name, state, _failures, _opened_at}] ->
        state

      [] ->
        :closed
    end
  end

  @doc "Reset a specific tool's circuit breaker."
  @spec reset(String.t()) :: :ok
  def reset(tool_name) do
    ensure_table()
    :ets.delete(@table, tool_name)
    :ok
  end

  @doc "Reset all circuit breakers."
  @spec reset_all() :: :ok
  def reset_all do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      init()
    end
  end
end
