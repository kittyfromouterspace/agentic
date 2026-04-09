defmodule AgentEx.ModelRouter do
  @moduledoc """
  Smart model routing for AgentEx with two selection modes.

  ## Modes

    * `:manual` — the caller picks a tier (`:primary`, `:lightweight`) and
      the router resolves the best route from the catalog. This is the
      legacy behaviour and the default.
    * `:auto` — the router analyses the request using a fast/free model,
      determines complexity and required capabilities, then selects the
      best model based on user preference (`:optimize_price` or
      `:optimize_speed`).

  ## Auto mode flow

      1. `Analyzer.analyze/2` classifies the request (complexity, capabilities)
      2. `Selector.select/3` scores all catalog models using the analysis
         and user preference
      3. The best-scoring model is returned as a route

  ## Manual mode flow

      1. Caller provides a `tier` (`:primary`, `:lightweight`, `:any`)
      2. Router queries the catalog, sorts by priority, returns healthy routes
  """

  use GenServer

  alias AgentEx.LLM.Catalog
  alias AgentEx.LLM.Model
  alias AgentEx.ModelRouter.{Preference, Selector}

  require Logger

  @health_table :agent_ex_route_health

  @type selection_mode :: :manual | :auto

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Auto-select the best model for a request given a user preference.

  Returns `{:ok, route, analysis}` or `{:error, reason}`.
  """
  def auto_select(request, preference \\ Preference.default(), opts \\ []) do
    GenServer.call(__MODULE__, {:auto_select, request, preference, opts})
  catch
    :exit, _ -> {:error, :router_unavailable}
  end

  @doc "Resolve the best route for a tier (manual mode)."
  def resolve(tier) do
    GenServer.call(__MODULE__, {:resolve, tier})
  catch
    :exit, _ -> {:error, :router_unavailable}
  end

  @doc "Get all available routes for a tier (manual mode)."
  def resolve_all(tier) do
    GenServer.call(__MODULE__, {:resolve_all, tier})
  catch
    :exit, _ -> {:error, :router_unavailable}
  end

  @doc """
  Resolve routes for a context — dispatches to auto or manual based on
  `ctx.model_selection_mode`.
  """
  def resolve_for_context(ctx) do
    mode = Map.get(ctx, :model_selection_mode, :manual)
    session_id = Map.get(ctx, :session_id)

    start_time = System.monotonic_time()

    AgentEx.Telemetry.event([:model_router, :resolve, :start], %{}, %{
      session_id: session_id,
      selection_mode: mode
    })

    result =
      case mode do
        :auto ->
          preference = Map.get(ctx, :model_preference, Preference.default())
          request = extract_request(ctx)
          llm_chat = (ctx.callbacks || %{})[:llm_chat]
          context_summary = build_context_summary(ctx)

          opts = [
            llm_chat: llm_chat,
            context_summary: context_summary,
            session_id: session_id
          ]

          case Selector.select(request, preference, opts) do
            {:ok, {model, analysis}} ->
              route = model_to_route(model)

              AgentEx.Telemetry.event(
                [:model_router, :resolve, :stop],
                %{
                  duration: System.monotonic_time() - start_time,
                  route_count: 1
                },
                %{
                  session_id: session_id,
                  selection_mode: :auto,
                  preference: preference,
                  selected_provider: model.provider,
                  selected_model_id: model.id,
                  complexity: analysis.complexity,
                  needs_vision: analysis.needs_vision,
                  needs_reasoning: analysis.needs_reasoning
                }
              )

              {:ok, [route], analysis}

            {:error, reason} ->
              AgentEx.Telemetry.event(
                [:model_router, :resolve, :stop],
                %{
                  duration: System.monotonic_time() - start_time
                },
                %{
                  session_id: session_id,
                  selection_mode: :auto,
                  error: reason
                }
              )

              {:error, reason}
          end

        :manual ->
          tier = Map.get(ctx, :model_tier, :primary)

          case resolve_all(tier) do
            {:ok, routes} ->
              AgentEx.Telemetry.event(
                [:model_router, :resolve, :stop],
                %{
                  duration: System.monotonic_time() - start_time,
                  route_count: length(routes)
                },
                %{
                  session_id: session_id,
                  selection_mode: :manual,
                  tier: tier
                }
              )

              {:ok, routes, nil}

            error ->
              AgentEx.Telemetry.event(
                [:model_router, :resolve, :stop],
                %{
                  duration: System.monotonic_time() - start_time
                },
                %{
                  session_id: session_id,
                  selection_mode: :manual,
                  tier: tier,
                  error: true
                }
              )

              error
          end
      end

    result
  end

  @doc "Report a successful call for a route."
  def report_success(provider_name, model_id) do
    GenServer.cast(__MODULE__, {:report_success, provider_name, model_id})
  end

  @doc "Report a failed call for a route."
  def report_error(provider_name, model_id, failure_type \\ :other, opts \\ []) do
    GenServer.cast(__MODULE__, {:report_error, provider_name, model_id, failure_type, opts})
  end

  @doc "Get current routing status."
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> %{health: %{}}
  end

  @doc "Configure workspace tier overrides."
  def set_tier_overrides(tiers) when is_map(tiers) do
    GenServer.cast(__MODULE__, {:set_tier_overrides, tiers})
  end

  @doc "Clear workspace tier overrides."
  def clear_tier_overrides do
    GenServer.cast(__MODULE__, :clear_tier_overrides)
  end

  @doc "Legacy compat: set routes for a tier (replaced by Catalog, kept for backward compat)."
  def set_routes(_tier, _routes) do
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@health_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{tier_overrides: %{}}}
  end

  @impl true
  def handle_call({:auto_select, request, preference, opts}, _from, state) do
    context_summary = Keyword.get(opts, :context_summary, "")
    llm_chat = Keyword.get(opts, :llm_chat)

    selector_opts = [context_summary: context_summary, llm_chat: llm_chat]

    result =
      case Selector.select(request, preference, selector_opts) do
        {:ok, {model, analysis}} ->
          route = model_to_route(model)

          AgentEx.Telemetry.event([:model_router, :auto_select], %{}, %{
            preference: preference,
            selected_provider: model.provider,
            selected_model_id: model.id,
            complexity: analysis.complexity
          })

          {:ok, route, analysis}

        {:error, reason} ->
          AgentEx.Telemetry.event([:model_router, :auto_select], %{}, %{
            preference: preference,
            error: reason
          })

          {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:resolve, tier}, _from, state) do
    routes = routes_for_tier(tier, state)

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
    routes = routes_for_tier(tier, state)
    {:reply, {:ok, routes}, state}
  end

  def handle_call(:status, _from, state) do
    health =
      @health_table
      |> :ets.tab2list()
      |> Map.new(fn {id, h} -> {id, h} end)

    status = %{
      tier_overrides: state.tier_overrides,
      health: health
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:set_tier_overrides, tiers}, state) do
    {:noreply, %{state | tier_overrides: tiers}}
  end

  def handle_cast(:clear_tier_overrides, state) do
    {:noreply, %{state | tier_overrides: %{}}}
  end

  def handle_cast({:report_success, _provider_name, model_id}, state) do
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

  def handle_cast({:report_error, _provider_name, model_id, failure_type, opts}, state) do
    retry_after_ms = Keyword.get(opts, :retry_after_ms)

    update_health(model_id, fn h ->
      new_count = h.error_count + 1

      cooldown_until =
        cond do
          is_integer(retry_after_ms) and retry_after_ms > 0 ->
            now_ms() + retry_after_ms

          new_count >= 2 ->
            cooldown = if failure_type == :rate_limit, do: 240_000, else: 120_000
            now_ms() + cooldown

          true ->
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

  # ----- route resolution via Catalog (manual mode) -----

  defp routes_for_tier(tier, state) do
    effective_tier = if tier == :any, do: nil, else: tier

    catalog_models =
      case effective_tier do
        nil ->
          Catalog.find(has: [:chat, :tools])

        t ->
          Catalog.find(tier: t, has: [:chat, :tools])
      end

    override_models =
      case effective_tier do
        nil -> []
        t -> resolve_override(t, state.tier_overrides)
      end

    all_models = override_models ++ catalog_models

    routes =
      all_models
      |> Enum.uniq_by(fn m -> {m.provider, m.id} end)
      |> Enum.map(&model_to_route/1)
      |> Enum.sort_by(& &1.priority)

    {healthy, unhealthy} = Enum.split_with(routes, &route_healthy?/1)
    healthy ++ unhealthy
  end

  defp resolve_override(tier, overrides) do
    case Map.get(overrides, tier) do
      nil ->
        []

      model_spec when is_binary(model_spec) ->
        case String.split(model_spec, "/", parts: 2) do
          [provider_str, model_id] ->
            provider = String.to_atom(provider_str)

            case Catalog.lookup(provider, model_id) do
              nil -> []
              model -> [model]
            end

          _ ->
            []
        end
    end
  end

  defp model_to_route(%Model{} = m) do
    status = if route_healthy_by_id?(m.id), do: :healthy, else: :unhealthy

    %{
      id: "catalog-#{m.provider}/#{m.id}",
      provider_name: Atom.to_string(m.provider),
      model_id: m.id,
      label: m.label || m.id,
      context_window: m.context_window,
      max_output_tokens: m.max_output_tokens,
      capabilities: m.capabilities,
      priority: route_priority(m),
      source: m.source,
      status: status,
      cost: m.cost
    }
  end

  defp route_priority(model) do
    cond do
      model.tier_hint == :primary -> 10
      model.tier_hint == :lightweight -> 20
      MapSet.member?(model.capabilities, :free) -> 30
      true -> 50
    end
  end

  defp route_healthy?(%{status: :unhealthy}), do: false
  defp route_healthy?(%{status: _}), do: true

  defp route_healthy_by_id?(model_id) do
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ----- context helpers for auto mode -----

  defp extract_request(ctx) do
    messages = ctx.messages || []

    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn msg ->
      if msg["role"] == "user" do
        case msg["content"] do
          text when is_binary(text) ->
            text

          blocks when is_list(blocks) ->
            blocks
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map_join(& &1["text"])

          _ ->
            ""
        end
      else
        nil
      end
    end)
  end

  defp build_context_summary(ctx) do
    parts = []

    parts =
      if ctx.metadata[:workspace] do
        ["Workspace: #{ctx.metadata[:workspace]}" | parts]
      else
        parts
      end

    parts =
      if ctx.tools != [] do
        tool_names = Enum.map(ctx.tools, & &1["name"]) |> Enum.join(", ")
        ["Available tools: #{tool_names}" | parts]
      else
        parts
      end

    parts =
      if ctx.mode do
        ["Mode: #{ctx.mode}" | parts]
      else
        parts
      end

    Enum.join(parts, "\n")
  end
end
