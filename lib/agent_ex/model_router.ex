defmodule AgentEx.ModelRouter do
  @moduledoc """
  Smart model routing for AgentEx.

  Provides two routing layers:

  1. **Free routes** — dynamically discovered from OpenRouter's free models
     that support tool use. Refreshed periodically, health-tracked.

  2. **Configured routes** — passed in via callback or config.

  The `llm_chat` callback receives resolved route info in params under
  `"_route"`, allowing the host to route to the correct provider.
  """

  alias AgentEx.ModelRouter.Free

  require Logger

  @tiers [:primary, :lightweight, :any]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolve the best route for a tier.

  Free routes are tried first, then configured fallback routes.
  """
  def resolve(tier) do
    GenServer.call(__MODULE__, {:resolve, tier})
  catch
    :exit, _ -> {:error, :router_unavailable}
  end

  @doc """
  Get all available routes for a tier (free + configured), ordered by priority.
  """
  def resolve_all(tier) do
    GenServer.call(__MODULE__, {:resolve_all, tier})
  catch
    :exit, _ -> {:error, :router_unavailable}
  end

  @doc "Report a successful call for a route."
  def report_success(provider_name, model_id) do
    GenServer.cast(__MODULE__, {:report_success, provider_name, model_id})
  end

  @doc "Report a failed call for a route."
  def report_error(provider_name, model_id, failure_type \\ :other) do
    GenServer.cast(__MODULE__, {:report_error, provider_name, model_id, failure_type})
  end

  @doc "Force refresh of free model catalog."
  def refresh_free_models do
    Free.refresh()
  end

  @doc "Get current routing status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Configure fallback routes for a tier."
  def set_routes(tier, routes) when tier in @tiers do
    GenServer.cast(__MODULE__, {:set_routes, tier, routes})
  end

  @doc "Clear all configured routes."
  def clear_routes do
    GenServer.cast(__MODULE__, :clear_routes)
  end

  @impl true
  def init(_opts) do
    {:ok, %{configured_routes: %{}}}
  end

  @impl true
  def handle_call({:resolve, tier}, _from, state) do
    routes = all_routes_for_tier(tier, state)

    result =
      case Enum.reject(routes, &(&1.status == :unhealthy)) do
        [] ->
          case List.first(routes) do
            nil -> {:error, :no_routes_available}
            route -> {:ok, route}
          end

        [first | _] ->
          {:ok, first}
      end

    {:reply, result, state}
  end

  def handle_call({:resolve_all, tier}, _from, state) do
    routes = all_routes_for_tier(tier, state)
    {:reply, {:ok, routes}, state}
  end

  def handle_call(:status, _from, state) do
    free_status = Free.status()

    status = %{
      configured: state.configured_routes,
      free: free_status
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:set_routes, tier, routes}, state) do
    normalized =
      Enum.map(routes, fn r ->
        %{
          id: r[:id] || r["id"] || UUID.uuid4(),
          provider_name: r[:provider_name] || r["provider_name"] || "unknown",
          model_id: r[:model_id] || r["model_id"],
          label: r[:label] || r["label"] || r[:model_id] || "Unknown",
          api_type: normalize_api_type(r[:api_type] || r["api_type"]),
          base_url: r[:base_url] || r["base_url"],
          api_key: r[:api_key] || r["api_key"],
          priority: r[:priority] || r["priority"] || 100,
          source: :configured
        }
      end)

    updated = Map.put(state.configured_routes, tier, normalized)
    {:noreply, %{state | configured_routes: updated}}
  end

  def handle_cast(:clear_routes, state) do
    {:noreply, %{state | configured_routes: %{}}}
  end

  def handle_cast({:report_success, provider_name, model_id}, state) do
    Free.report_success(model_id)
    {:noreply, state}
  end

  def handle_cast({:report_error, provider_name, model_id, failure_type}, state) do
    Free.report_error(model_id, failure_type)
    {:noreply, state}
  end

  defp all_routes_for_tier(tier, state) do
    effective_tier = if tier == :any, do: :lightweight, else: tier

    free = Free.free_routes(effective_tier)

    configured =
      state.configured_routes
      |> Map.get(effective_tier, [])
      |> Enum.map(&Map.put(&1, :status, :healthy))

    # Free routes first (priority), then configured
    free ++ configured
  end

  defp normalize_api_type(nil), do: :openai_compatible
  defp normalize_api_type(type) when is_atom(type), do: type
  defp normalize_api_type(type) when is_binary(type), do: String.to_existing_atom(type)
end
