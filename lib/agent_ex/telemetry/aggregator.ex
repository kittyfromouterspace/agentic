defmodule AgentEx.Telemetry.Aggregator do
  @moduledoc """
  GenServer that maintains running aggregates of orchestration telemetry events.

  Attaches to `[:agent_ex, :orchestration, :turn]` and
  `[:agent_ex, :orchestration, :tool_executed]` events and keeps
  per-`(strategy, mode)` counters.

  ## Usage

      Aggregator.summary(:default)
      Aggregator.summary(:default, :agentic)
  """

  use GenServer

  @handler_id "agent-ex-orchestration-aggregator"

  defstruct counts: %{}

  @type entry :: %{
          turn_count: non_neg_integer(),
          total_duration_ms: non_neg_integer(),
          tool_call_count: non_neg_integer(),
          tool_success_count: non_neg_integer(),
          error_count: non_neg_integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return aggregated stats for a strategy."
  @spec summary(atom()) :: %{optional(atom()) => entry()}
  def summary(strategy) do
    GenServer.call(__MODULE__, {:summary, strategy})
  catch
    :exit, _ -> %{}
  end

  @doc "Return aggregated stats for a strategy + mode pair."
  @spec summary(atom(), atom()) :: entry()
  def summary(strategy, mode) do
    GenServer.call(__MODULE__, {:summary, strategy, mode})
  catch
    :exit, _ -> empty_entry()
  end

  @doc "Reset all counters."
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      @handler_id,
      [
        [:agent_ex, :orchestration, :turn],
        [:agent_ex, :orchestration, :tool_executed]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:summary, strategy}, _from, state) do
    result =
      state.counts
      |> Enum.filter(fn {{s, _m}, _e} -> s == strategy end)
      |> Enum.map(fn {{_s, m}, e} -> {m, e} end)
      |> Map.new()

    {:reply, result, state}
  end

  def handle_call({:summary, strategy, mode}, _from, state) do
    entry = Map.get(state.counts, {strategy, mode}, empty_entry())
    {:reply, entry, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:turn, metadata}, state) do
    strategy = metadata[:strategy] || :default
    mode = metadata[:mode]
    stop_reason = metadata[:stop_reason]

    state = bump(state, {strategy, mode}, :turn_count)

    state =
      if stop_reason == :max_tokens do
        bump(state, {strategy, mode}, :error_count)
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:tool_executed, measurements, metadata}, state) do
    strategy = metadata[:strategy] || :default
    mode = metadata[:mode]

    state = bump(state, {strategy, mode}, :tool_call_count)

    state =
      if metadata[:success] do
        bump(state, {strategy, mode}, :tool_success_count)
      else
        state
      end

    state =
      case measurements[:duration] do
        nil -> state
        d -> bump(state, {strategy, mode}, :total_duration_ms, d)
      end

    {:noreply, state}
  end

  @doc false
  def handle_event([:agent_ex, :orchestration, :turn], _measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:turn, metadata})
  end

  def handle_event([:agent_ex, :orchestration, :tool_executed], measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:tool_executed, measurements, metadata})
  end

  defp bump(state, key, field, amount \\ 1) do
    updated_counts =
      update_in(state.counts, [Access.key(key, empty_entry()), field], &(&1 + amount))

    %{state | counts: updated_counts}
  end

  defp empty_entry do
    %{
      turn_count: 0,
      total_duration_ms: 0,
      tool_call_count: 0,
      tool_success_count: 0,
      error_count: 0
    }
  end
end
