defmodule Agentic.LLM.Timeout do
  @moduledoc """
  Adaptive HTTP receive-timeout for LLM gateway calls.

  A fixed 120 s cut off slow-but-valid completions from heavy reasoning models
  (e.g. `kimi-for-coding`, which can spend minutes thinking before emitting
  visible output) → spurious `:timeout` classifications and retries that make an
  agent crawl. This tracks a slowly-decaying peak of recent LLM call wall
  durations and returns `clamp(factor * peak, floor, ceiling)`, so the timeout
  self-tunes to whatever the provider actually needs — generous when the model
  is slow, tighter when it's fast — bounded at both ends. A run of timeouts
  (whose elapsed ≈ the current timeout) ratchets the value up toward the ceiling.

  Config (`config :agentic, Agentic.LLM.Timeout, ...`):

    * `:floor_ms`   — minimum timeout, the base (default `180_000` = 3 min)
    * `:ceiling_ms` — maximum timeout (default `600_000` = 10 min)
    * `:factor`     — multiple of the observed peak (default `3.0`)
    * `:decay`      — per-observation decay of the peak (default `0.97`)

  Reads go through a `GenServer.call` (microseconds, negligible beside a
  multi-second LLM call) and fall back to `floor_ms` if the tracker isn't
  running, so the gateway never breaks when agentic runs unsupervised.
  """

  use GenServer

  @name __MODULE__

  # --- API ---

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @doc "The current adaptive receive-timeout, in milliseconds."
  @spec receive_timeout() :: pos_integer()
  def receive_timeout do
    GenServer.call(@name, :timeout, 1_000)
  catch
    :exit, _ -> cfg(:floor_ms, 180_000)
  end

  @doc "Record a completed LLM call's wall duration (ms) so the timeout adapts."
  @spec observe(number()) :: :ok
  def observe(duration_ms) when is_number(duration_ms) and duration_ms > 0 do
    GenServer.cast(@name, {:observe, duration_ms})
  catch
    :exit, _ -> :ok
  end

  def observe(_), do: :ok

  # --- server ---

  @impl true
  def init(_), do: {:ok, %{peak: nil}}

  @impl true
  def handle_call(:timeout, _from, state) do
    {:reply, compute(state.peak), state}
  end

  @impl true
  def handle_cast({:observe, d}, %{peak: peak} = state) do
    new_peak = max(d, (peak || 0) * cfg(:decay, 0.97))
    {:noreply, %{state | peak: new_peak}}
  end

  # --- internals ---

  defp compute(nil), do: cfg(:floor_ms, 180_000)

  defp compute(peak) do
    (cfg(:factor, 3.0) * peak)
    |> round()
    |> max(cfg(:floor_ms, 180_000))
    |> min(cfg(:ceiling_ms, 600_000))
  end

  defp cfg(key, default) do
    :agentic
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
