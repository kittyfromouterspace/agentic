defmodule AgentEx.ModelRouter.Free do
  @moduledoc """
  Free OpenRouter model discovery and routing.

  Periodically fetches the OpenRouter model catalog, identifies free models
  that support tool use, and categorizes them by tier:

  - `:primary` — Best free model (largest context, reasoning models preferred)
  - `:lightweight` — Fastest free model (smallest viable context)

  Health tracking with cooldowns ensures automatic rotation when a free
  model gets rate-limited.
  """

  use GenServer

  require Logger

  @health_table :agent_ex_free_model_health
  @refresh_interval_ms 10 * 60 * 1000
  @cooldown_ms 120_000
  @error_threshold 2
  @models_url "https://openrouter.ai/api/v1/models"
  @fetch_timeout 15_000

  @primary_min_context 64_000
  @lightweight_min_context 8_000

  defmodule Route do
    @moduledoc false
    defstruct [
      :id,
      :model_id,
      :display_name,
      :context_window,
      :max_completion_tokens,
      :supports_reasoning,
      :provider_name,
      :api_type,
      :base_url,
      :priority,
      :source
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def free_routes(tier) when tier in [:primary, :lightweight] do
    GenServer.call(__MODULE__, {:free_routes, tier})
  catch
    :exit, _ -> []
  end

  def free_routes(_tier), do: []

  def report_success(model_id) when is_binary(model_id) do
    GenServer.cast(__MODULE__, {:report_success, model_id})
  end

  def report_error(model_id, failure_type \\ :other) when is_binary(model_id) do
    GenServer.cast(__MODULE__, {:report_error, model_id, failure_type})
  end

  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    :ets.new(@health_table, [:named_table, :set, :public, read_concurrency: true])
    send(self(), :refresh)
    {:ok, %{models: %{primary: [], lightweight: []}, last_refresh: nil, refresh_timer: nil}}
  end

  @impl true
  def handle_call({:free_routes, tier}, _from, state) do
    routes =
      state.models
      |> Map.get(tier, [])
      |> Enum.filter(&model_healthy?(&1.model_id))
      |> Enum.map(&to_route/1)

    {:reply, routes, state}
  end

  def handle_call(:status, _from, state) do
    health =
      @health_table
      |> :ets.tab2list()
      |> Map.new(fn {id, h} -> {id, h} end)

    {:reply, %{models: state.models, last_refresh: state.last_refresh, health: health}, state}
  end

  @impl true
  def handle_cast({:report_success, model_id}, state) do
    update_health(model_id, fn h ->
      %{
        h
        | error_count: 0,
          cooldown_until: nil,
          last_success_at: now_ms(),
          consecutive_successes: (h.consecutive_successes || 0) + 1
      }
    end)

    {:noreply, state}
  end

  def handle_cast({:report_error, model_id, failure_type}, state) do
    update_health(model_id, fn h ->
      new_count = h.error_count + 1

      cooldown_until =
        if new_count >= @error_threshold do
          cooldown = if failure_type == :rate_limit, do: @cooldown_ms * 2, else: @cooldown_ms
          now_ms() + cooldown
        else
          h.cooldown_until
        end

      %{
        h
        | error_count: new_count,
          cooldown_until: cooldown_until,
          last_error_at: now_ms(),
          consecutive_successes: 0
      }
    end)

    {:noreply, state}
  end

  def handle_cast(:refresh, state) do
    send(self(), :refresh)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)

    models = fetch_and_categorize()
    timer = Process.send_after(self(), :refresh, @refresh_interval_ms)

    primary_ids = Enum.map(models.primary, & &1.model_id)
    lightweight_ids = Enum.map(models.lightweight, & &1.model_id)

    Logger.info(
      "AgentEx.ModelRouter.Free: refreshed. Primary: #{inspect(primary_ids)}, Lightweight: #{inspect(lightweight_ids)}"
    )

    all_model_ids = MapSet.new(primary_ids ++ lightweight_ids)
    prune_stale_health(all_model_ids)

    {:noreply, %{state | models: models, last_refresh: DateTime.utc_now(), refresh_timer: timer}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fetch_and_categorize do
    case fetch_models() do
      {:ok, models} ->
        free_with_tools =
          models
          |> Enum.filter(&free_with_tools?/1)
          |> Enum.filter(&text_output?/1)
          |> Enum.map(&parse_free_model/1)

        categorize(free_with_tools)

      {:error, reason} ->
        Logger.warning("AgentEx.ModelRouter.Free: failed to fetch models: #{inspect(reason)}")
        %{primary: [], lightweight: []}
    end
  end

  defp fetch_models do
    case Req.get(@models_url, receive_timeout: @fetch_timeout) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok, models}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp free_with_tools?(model) do
    pricing = model["pricing"] || %{}
    params = model["supported_parameters"] || []

    pricing["prompt"] == "0" and
      pricing["completion"] == "0" and
      "tools" in params
  end

  defp text_output?(model) do
    output = get_in(model, ["architecture", "output_modalities"]) || []
    "text" in output
  end

  defp parse_free_model(raw) do
    %{
      model_id: raw["id"],
      display_name: raw["name"] || raw["id"],
      context_window: raw["context_length"] || 0,
      max_completion_tokens: get_in(raw, ["top_provider", "max_completion_tokens"]),
      supports_reasoning: detect_reasoning(raw)
    }
  end

  defp detect_reasoning(raw) do
    params = raw["supported_parameters"] || []
    id = raw["id"] || ""

    "reasoning" in params or
      String.contains?(id, "thinking") or
      String.contains?(id, "-r1") or
      String.contains?(id, "-reasoner")
  end

  defp categorize(free_models) do
    primary =
      free_models
      |> Enum.filter(&(&1.context_window >= @primary_min_context))
      |> Enum.sort_by(fn m ->
        reasoning_bonus = if m.supports_reasoning, do: 1_000_000, else: 0
        -(m.context_window + reasoning_bonus)
      end)

    lightweight =
      free_models
      |> Enum.filter(&(&1.context_window >= @lightweight_min_context))
      |> Enum.sort_by(& &1.context_window)

    %{primary: primary, lightweight: lightweight}
  end

  defp model_healthy?(model_id) do
    case :ets.lookup(@health_table, model_id) do
      [{_, health}] ->
        case health.cooldown_until do
          nil -> true
          ts -> now_ms() > ts
        end

      [] ->
        true
    end
  end

  defp update_health(model_id, fun) do
    current =
      case :ets.lookup(@health_table, model_id) do
        [{_, h}] -> h
        [] -> default_health()
      end

    :ets.insert(@health_table, {model_id, fun.(current)})
  end

  defp default_health do
    %{
      error_count: 0,
      cooldown_until: nil,
      last_success_at: nil,
      last_error_at: nil,
      consecutive_successes: 0
    }
  end

  defp prune_stale_health(current_model_ids) do
    @health_table
    |> :ets.tab2list()
    |> Enum.each(fn {id, _} ->
      if !MapSet.member?(current_model_ids, id) do
        :ets.delete(@health_table, id)
      end
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp to_route(m) do
    %{
      id: "free-#{m.model_id}",
      provider_name: "openrouter",
      model_id: m.model_id,
      label: m.display_name,
      api_type: :openai_completions,
      base_url: "https://openrouter.ai/api/v1",
      priority: 10,
      source: :free
    }
  end
end
