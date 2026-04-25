defmodule Agentic.ModelRouter do
  @moduledoc """
  Smart model routing for Agentic with two selection modes.

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

  alias Agentic.LLM.Catalog
  alias Agentic.LLM.Model
  alias Agentic.LLM.ProviderAccount
  alias Agentic.ModelRouter.Preference
  alias Agentic.ModelRouter.Selector

  require Logger

  @health_table :agentic_route_health

  # Where we persist route health between restarts. Uses ms-since-epoch
  # timestamps so cooldowns and "verified" markers survive boots.
  @health_path Path.join([System.user_home() || ".", ".agentic", "route_health.json"])
  @sticky_path Path.join([System.user_home() || ".", ".agentic", "route_sticky.json"])

  # Debounce window for health flushes. Casts arrive in bursts; we
  # coalesce them into one disk write.
  @flush_debounce_ms 1_500

  # A route is treated as "recently broken" if its last failure was
  # within this window without a subsequent success. Boosts the priority
  # of routes that have actually worked.
  @recent_failure_window_ms 30 * 60 * 1000

  # Sticky routes expire after this window so we re-explore the catalog
  # periodically even when the sticky pick is still working — newly
  # added or recovered models get a chance to climb back.
  @sticky_max_age_ms 6 * 60 * 60 * 1000

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
  Get all available routes for a tier, scored against the supplied
  per-provider accounts (for cost_profile + quota_pressure + availability).
  Pass `nil` to fall back to default `:pay_per_token`/`:ready` accounts —
  matches the behaviour of `resolve_all/1`.
  """
  def resolve_all_with_accounts(tier, accounts) do
    GenServer.call(__MODULE__, {:resolve_all_with_accounts, tier, accounts})
  catch
    :exit, _ -> {:error, :router_unavailable}
  end

  @doc """
  Like `resolve_all_with_accounts/2`, but also accepts a
  `canonical_id => preferred_provider_atom` map and the user's price/
  speed preference. Pathways whose provider is the user's preferred
  pathway for their canonical group get a strong score bonus (acts
  as a hard tie-breaker — within a canonical group, the user's pick
  wins over the cost-derived ranking unless that pick is
  `:unavailable`). The preference (`:optimize_price` |
  `:optimize_speed`) is threaded into `Preference.score_pathway/3` so
  the canonical grouping reflects the user's real ranking criterion
  rather than always defaulting to price.
  """
  def resolve_all_with_context(tier, accounts, pathway_preferences, preference \\ :optimize_price) do
    GenServer.call(
      __MODULE__,
      {:resolve_all_with_context, tier, accounts, pathway_preferences, preference}
    )
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

    Agentic.Telemetry.event([:model_router, :resolve, :start], %{}, %{
      session_id: session_id,
      selection_mode: mode
    })

    case lookup_sticky(ctx) do
      {:ok, sticky_route, fallback_routes} ->
        Logger.debug(
          "ModelRouter: sticky route hit #{sticky_route.provider_name}/#{sticky_route.model_id}"
        )

        Agentic.Telemetry.event(
          [:model_router, :resolve, :stop],
          %{duration: System.monotonic_time() - start_time, route_count: 1, sticky: true},
          %{
            session_id: session_id,
            selection_mode: mode,
            tier: sticky_route_tier(ctx),
            selected_provider: sticky_route.provider_name,
            selected_model_id: sticky_route.model_id
          }
        )

        case mode do
          :auto -> {:ok, [sticky_route | fallback_routes], nil, []}
          :manual -> {:ok, [sticky_route | fallback_routes], nil}
        end

      :miss ->
        do_resolve_for_context(ctx, mode, session_id, start_time)
    end
  end

  defp do_resolve_for_context(ctx, mode, session_id, start_time) do
    result =
      case mode do
        :auto ->
          preference = Map.get(ctx, :model_preference, Preference.default())
          request = extract_request(ctx)
          llm_chat = (ctx.callbacks || %{})[:llm_chat]
          context_summary = build_context_summary(ctx)

          model_filter = Map.get(ctx, :model_filter)

          opts = [
            llm_chat: llm_chat,
            context_summary: context_summary,
            session_id: session_id,
            model_filter: model_filter
          ]

          case Selector.select_all(request, preference, opts) do
            {:ok, {models, analysis, scores}} ->
              routes = Enum.map(models, &model_to_route/1)
              best = List.first(models)

              Agentic.Telemetry.event(
                [:model_router, :resolve, :stop],
                %{
                  duration: System.monotonic_time() - start_time,
                  route_count: length(routes)
                },
                %{
                  session_id: session_id,
                  selection_mode: :auto,
                  preference: preference,
                  selected_provider: best && best.provider,
                  selected_model_id: best && best.id,
                  complexity: analysis.complexity,
                  needs_vision: analysis.needs_vision,
                  needs_reasoning: analysis.needs_reasoning
                }
              )

              {:ok, routes, analysis, scores}

            {:error, reason} ->
              Agentic.Telemetry.event(
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
          model_filter = Map.get(ctx, :model_filter)
          accounts = (ctx.metadata || %{})[:provider_accounts]
          pathway_preferences = (ctx.metadata || %{})[:pathway_preferences] || %{}
          # Pull the user's price/speed preference so canonical
          # grouping reflects it. Defaults to :optimize_price for the
          # legacy manual-mode flow that never declared a preference.
          preference = Map.get(ctx, :model_preference, :optimize_price)

          case resolve_all_with_context(tier, accounts, pathway_preferences, preference) do
            {:ok, routes} ->
              routes = filter_routes(routes, model_filter)

              if routes == [] do
                Agentic.Telemetry.event(
                  [:model_router, :resolve, :stop],
                  %{
                    duration: System.monotonic_time() - start_time,
                    route_count: 0
                  },
                  %{
                    session_id: session_id,
                    selection_mode: :manual,
                    tier: tier,
                    model_filter: model_filter,
                    error: :no_routes_after_filter
                  }
                )

                {:error, :no_free_models_available}
              else
                Agentic.Telemetry.event(
                  [:model_router, :resolve, :stop],
                  %{
                    duration: System.monotonic_time() - start_time,
                    route_count: length(routes)
                  },
                  %{
                    session_id: session_id,
                    selection_mode: :manual,
                    tier: tier,
                    model_filter: model_filter
                  }
                )

                {:ok, routes, nil}
              end

            error ->
              Agentic.Telemetry.event(
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

  @doc """
  Report a successful call for a route.

  Pass `sticky: %{tier: tier, filter: filter}` to mark this route as the
  current sticky pick for that bucket; future `resolve_for_context/1`
  calls with the same bucket will return this route directly without
  re-running selection.
  """
  def report_success(provider_name, model_id, opts \\ []) do
    GenServer.cast(__MODULE__, {:report_success, provider_name, model_id, opts})
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
    load_health_from_disk()

    {:ok,
     %{
       tier_overrides: %{},
       flush_pending?: false,
       sticky_pending?: false,
       sticky: load_sticky_from_disk()
     }}
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

          Agentic.Telemetry.event([:model_router, :auto_select], %{}, %{
            preference: preference,
            selected_provider: model.provider,
            selected_model_id: model.id,
            complexity: analysis.complexity
          })

          {:ok, route, analysis}

        {:error, reason} ->
          Agentic.Telemetry.event([:model_router, :auto_select], %{}, %{
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

  def handle_call({:resolve_all_with_accounts, tier, accounts}, _from, state) do
    routes = routes_for_tier(tier, state, accounts)
    {:reply, {:ok, routes}, state}
  end

  def handle_call(
        {:resolve_all_with_context, tier, accounts, pathway_preferences, preference},
        _from,
        state
      ) do
    routes = routes_for_tier(tier, state, accounts, pathway_preferences, preference)
    {:reply, {:ok, routes}, state}
  end

  # Backwards-compat: pre-preference clause kept until any in-flight
  # callers shake out. New code uses the 5-tuple variant above.
  def handle_call({:resolve_all_with_context, tier, accounts, pathway_preferences}, from, state) do
    handle_call(
      {:resolve_all_with_context, tier, accounts, pathway_preferences, :optimize_price},
      from,
      state
    )
  end

  def handle_call({:get_sticky, bucket}, _from, state) do
    {:reply, Map.get(state.sticky, bucket), state}
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

  def handle_cast({:report_success, provider_name, model_id, opts}, state) do
    now = now_ms()

    update_health(model_id, fn h ->
      %{
        h
        | error_count: 0,
          cooldown_until: nil,
          last_success_at: now,
          last_error_kind: nil,
          consecutive_successes: (h.consecutive_successes || 0) + 1,
          verified_at: h.verified_at || now
      }
    end)

    state =
      case Keyword.get(opts, :sticky) do
        %{} = bucket ->
          set_sticky(state, bucket, provider_name, model_id, now)

        _ ->
          state
      end

    {:noreply, state |> schedule_flush() |> schedule_sticky_flush()}
  end

  # Backwards compat for older callers that didn't pass opts.
  def handle_cast({:report_success, provider_name, model_id}, state) do
    handle_cast({:report_success, provider_name, model_id, []}, state)
  end

  def handle_cast({:report_error, _provider_name, model_id, failure_type, opts}, state) do
    retry_after_ms = Keyword.get(opts, :retry_after_ms)
    now = now_ms()

    update_health(model_id, fn h ->
      new_count = h.error_count + 1

      cooldown_until =
        cond do
          is_integer(retry_after_ms) and retry_after_ms > 0 ->
            now + retry_after_ms

          new_count >= 2 ->
            now + cooldown_for(failure_type)

          failure_type in [:auth_error, :empty_response] ->
            # First failure of these kinds is enough to demote — they
            # don't tend to flip back without external action.
            now + cooldown_for(failure_type)

          true ->
            h.cooldown_until
        end

      %{
        h
        | error_count: new_count,
          cooldown_until: cooldown_until,
          last_error_at: now,
          last_error_kind: failure_type,
          consecutive_successes: 0
      }
    end)

    state = drop_matching_sticky(state, model_id)

    {:noreply, state |> schedule_flush() |> schedule_sticky_flush()}
  end

  @impl true
  def handle_info(:flush_health, state) do
    flush_health_to_disk()
    {:noreply, %{state | flush_pending?: false}}
  end

  def handle_info(:flush_sticky, state) do
    flush_sticky_to_disk(state.sticky)
    {:noreply, %{state | sticky_pending?: false}}
  end

  # ----- route resolution via Catalog (manual mode) -----

  defp routes_for_tier(tier, state, accounts \\ nil, pathway_preferences \\ %{}, preference \\ :optimize_price) do
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

    all_models =
      (override_models ++ catalog_models)
      |> Enum.uniq_by(fn m -> {m.provider, m.id} end)

    # Group pathways by canonical model so we score Anthropic-direct vs
    # Claude-Code vs OpenRouter as alternatives, not as separate routes.
    routes =
      all_models
      |> Enum.group_by(&canonical_key/1)
      |> Enum.map(fn {canonical, models} ->
        preferred_provider = Map.get(pathway_preferences, canonical)

        scored_pathways =
          models
          |> Enum.map(fn m ->
            account = ProviderAccount.for_provider(accounts, m.provider)
            base = score_for_pathway(m, account, preference)
            preference_bonus = if preferred_provider == m.provider, do: -100.0, else: 0.0
            {m, account, base + preference_bonus}
          end)
          |> Enum.reject(fn {_m, account, _score} ->
            account.availability == :unavailable
          end)

        case scored_pathways do
          [] ->
            nil

          pathways ->
            {model, account, pathway_score} =
              Enum.min_by(pathways, fn {_m, _a, s} -> s end)

            model_to_route(model, account, canonical, pathway_score, pathways)
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.priority)

    {healthy, unhealthy} = Enum.split_with(routes, &route_healthy?/1)
    healthy ++ unhealthy
  end

  # Stable canonical key — falls back to "<provider>:<id>" if the
  # canonical_id was never resolved.
  defp canonical_key(%Model{canonical_id: nil} = m), do: "#{m.provider}:#{m.id}"
  defp canonical_key(%Model{canonical_id: c}) when is_binary(c), do: c

  # Compute the pathway score for `(model, account, preference)`.
  # Falls back to `:optimize_price` for callers that pre-date the
  # preference plumbing. The historical manual-mode flow always
  # ranked by price, so that's the safe default.
  defp score_for_pathway(%Model{} = model, %ProviderAccount{} = account, preference) do
    Preference.score_pathway(model, account, preference)
  end

  defp score_for_pathway(%Model{} = model, %ProviderAccount{} = account) do
    score_for_pathway(model, account, :optimize_price)
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
    account = ProviderAccount.default(m.provider)
    canonical = m.canonical_id || canonical_key(m)
    pathway_score = score_for_pathway(m, account)
    model_to_route(m, account, canonical, pathway_score, [{m, account, pathway_score}])
  end

  defp model_to_route(%Model{} = m, %ProviderAccount{} = account, canonical, pathway_score, pathways) do
    health = lookup_health(m.id)
    status = if route_healthy_record?(health), do: :healthy, else: :unhealthy

    fallbacks =
      pathways
      |> Enum.reject(fn {pm, _a, _s} -> pm.id == m.id and pm.provider == m.provider end)
      |> Enum.sort_by(fn {_pm, _a, s} -> s end)
      |> Enum.map(fn {pm, pa, s} ->
        %{
          provider_name: Atom.to_string(pm.provider),
          model_id: pm.id,
          account_id: pa.account_id,
          cost_profile: pa.cost_profile,
          score: s
        }
      end)

    %{
      id: "catalog-#{canonical}",
      canonical_model_id: canonical,
      provider_name: Atom.to_string(m.provider),
      model_id: m.id,
      account_id: account.account_id,
      cost_profile: account.cost_profile,
      pathway_score: pathway_score,
      pathway_fallbacks: fallbacks,
      label: m.label || m.id,
      context_window: m.context_window,
      max_output_tokens: m.max_output_tokens,
      capabilities: m.capabilities,
      priority: route_priority(m, health),
      source: m.source,
      status: status,
      cost: m.cost,
      endpoints: m.endpoints
    }
  end

  # Lower number = higher priority. Layered scoring:
  #   * tier_hint sets the bucket (primary < lightweight < tier-less)
  #   * source breaks ties so user_config beats static beats discovered
  #   * free models within a bucket sort below paid ones, since
  #     OpenRouter free routes are rate-limited and frequently unreliable
  #   * a route that has *actually worked* (verified_at set) gets a
  #     small boost over peers that haven't been tried
  #   * a route that recently failed without a subsequent success gets
  #     a large penalty so we don't keep slamming a broken endpoint
  #   * endpoint uptime from OpenRouter's /endpoints API gives a
  #     real-time reliability signal for multi-provider models
  defp route_priority(model, health) do
    base =
      case model.tier_hint do
        :primary -> 100
        :lightweight -> 200
        _ -> 500
      end

    source_bonus =
      case model.source do
        :user_config -> 0
        :static -> 5
        :discovered -> 15
        _ -> 20
      end

    free_penalty = if MapSet.member?(model.capabilities, :free), do: 40, else: 0
    verified_bonus = if health.verified_at, do: -3, else: 0

    failure_penalty =
      cond do
        recently_failed?(health) and not recently_succeeded?(health) ->
          # A persistent failure outweighs source/free preferences but
          # still keeps the route in the candidate list — the cooldown
          # eventually expires and another reorder may pick it back up.
          80

        true ->
          0
      end

    endpoint_penalty = endpoint_health_penalty(model.endpoints)

    base + source_bonus + free_penalty + verified_bonus + failure_penalty + endpoint_penalty
  end

  # Compute a penalty based on OpenRouter endpoint uptime data.
  # When no endpoint data is available (nil or empty) we apply no penalty.
  # When average uptime is poor we penalise the model so healthier
  # alternatives rise above it.
  defp endpoint_health_penalty(nil), do: 0
  defp endpoint_health_penalty([]), do: 0

  defp endpoint_health_penalty(endpoints) do
    avg_uptime =
      endpoints
      |> Enum.map(& &1[:uptime_last_30m])
      |> Enum.reject(&is_nil/1)
      |> average_uptime()

    cond do
      avg_uptime >= 99 -> -3
      avg_uptime >= 95 -> 0
      avg_uptime >= 90 -> 15
      avg_uptime >= 80 -> 30
      true -> 50
    end
  end

  defp average_uptime([]), do: 100.0

  defp average_uptime(values) do
    Enum.sum(values) / length(values)
  end

  defp recently_failed?(%{last_error_at: nil}), do: false
  defp recently_failed?(%{last_error_at: ts}), do: now_ms() - ts < @recent_failure_window_ms

  defp recently_succeeded?(%{last_success_at: nil}), do: false

  defp recently_succeeded?(%{last_success_at: success_at, last_error_at: error_at}) do
    case error_at do
      nil -> true
      err -> success_at > err
    end
  end

  defp route_healthy?(%{status: :unhealthy}), do: false
  defp route_healthy?(%{status: _}), do: true

  defp route_healthy_record?(%{cooldown_until: nil}), do: true
  defp route_healthy_record?(%{cooldown_until: ts}), do: now_ms() > ts

  defp lookup_health(model_id) do
    case :ets.lookup(@health_table, model_id) do
      [{_, h}] -> Map.merge(default_health(), h)
      [] -> default_health()
    end
  end

  defp update_health(model_id, fun) do
    current = lookup_health(model_id)
    :ets.insert(@health_table, {model_id, fun.(current)})
  end

  defp default_health do
    %{
      error_count: 0,
      cooldown_until: nil,
      last_success_at: nil,
      last_error_at: nil,
      last_error_kind: nil,
      consecutive_successes: 0,
      verified_at: nil
    }
  end

  defp cooldown_for(:rate_limit), do: 240_000
  defp cooldown_for(:auth_error), do: 30 * 60 * 1000
  defp cooldown_for(:empty_response), do: 30 * 60 * 1000
  defp cooldown_for(_), do: 120_000

  # Wall-clock time so cooldowns survive restarts. Monotonic time would
  # reset on every boot and effectively erase persisted health.
  defp now_ms, do: System.system_time(:millisecond)

  # ----- sticky route selection -----

  # The "bucket" is the dimension the sticky pick depends on: tier and
  # filter together. Auto and manual modes share the same bucket so that
  # toggling between them doesn't blow away the sticky pick — the
  # underlying choice (which model to call) is the same either way.
  defp bucket_key(ctx) do
    tier = Map.get(ctx, :model_tier, :primary) || :primary
    filter = Map.get(ctx, :model_filter)
    {tier, filter}
  end

  defp lookup_sticky(ctx) do
    bucket = bucket_key(ctx)

    case sticky_record(bucket) do
      nil ->
        :miss

      %{provider_name: provider, model_id: model_id, set_at: set_at} ->
        if now_ms() - set_at > @sticky_max_age_ms do
          :miss
        else
          state = GenServer.call(__MODULE__, :status)
          # ETS-only check; cheaper than re-running the full pipeline.
          health = lookup_health(model_id)

          model = lookup_model(provider, model_id)

          cond do
            is_nil(model) ->
              :miss

            not route_healthy_record?(health) ->
              :miss

            true ->
              route = model_to_route(model)
              fallback = remaining_routes(model, ctx, state)
              {:ok, route, fallback}
          end
        end
    end
  rescue
    _ -> :miss
  catch
    :exit, _ -> :miss
  end

  defp sticky_record(bucket) do
    GenServer.call(__MODULE__, {:get_sticky, bucket})
  catch
    :exit, _ -> nil
  end

  defp sticky_route_tier(ctx) do
    {tier, _filter} = bucket_key(ctx)
    tier
  end

  defp lookup_model(provider_name, model_id) when is_binary(provider_name) do
    case safe_atom(provider_name) do
      nil -> nil
      provider -> Catalog.lookup(provider, model_id)
    end
  end

  defp lookup_model(_, _), do: nil

  defp remaining_routes(sticky_model, ctx, state) do
    tier = Map.get(ctx, :model_tier, :primary) || :primary
    filter = Map.get(ctx, :model_filter)

    routes =
      tier
      |> routes_for_tier(state)
      |> Enum.reject(fn r ->
        r.provider_name == Atom.to_string(sticky_model.provider) and
          r.model_id == sticky_model.id
      end)

    case filter do
      :free_only -> Enum.filter(routes, &MapSet.member?(&1.capabilities, :free))
      _ -> routes
    end
  end

  defp set_sticky(state, %{} = bucket_input, provider_name, model_id, now) do
    bucket =
      case bucket_input do
        %{tier: t, filter: f} -> {t || :primary, f}
        %{tier: t} -> {t || :primary, nil}
        _ -> {:primary, nil}
      end

    canonical =
      case lookup_model(provider_name, model_id) do
        nil -> nil
        model -> model.canonical_id || canonical_key(model)
      end

    record = %{
      provider_name: provider_name,
      model_id: model_id,
      canonical_id: canonical,
      set_at: now
    }

    %{state | sticky: Map.put(state.sticky, bucket, record)}
  end

  defp drop_matching_sticky(state, model_id) do
    pruned =
      state.sticky
      |> Enum.reject(fn {_bucket, %{model_id: id}} -> id == model_id end)
      |> Map.new()

    %{state | sticky: pruned}
  end

  defp schedule_sticky_flush(%{sticky_pending?: true} = state), do: state

  defp schedule_sticky_flush(state) do
    Process.send_after(self(), :flush_sticky, @flush_debounce_ms)
    %{state | sticky_pending?: true}
  end

  defp flush_sticky_to_disk(sticky) do
    File.mkdir_p!(Path.dirname(@sticky_path))

    serialisable =
      sticky
      |> Enum.map(fn {{tier, filter}, record} ->
        {"#{tier}|#{filter || ""}", record}
      end)
      |> Map.new()

    case Jason.encode(serialisable) do
      {:ok, json} -> File.write(@sticky_path, json)
      {:error, reason} ->
        Logger.warning("ModelRouter: failed to encode sticky snapshot: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("ModelRouter: failed to flush sticky: #{Exception.message(e)}")
  end

  defp load_sticky_from_disk do
    with {:ok, body} <- File.read(@sticky_path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      Enum.reduce(decoded, %{}, fn {key, raw}, acc ->
        case String.split(key, "|", parts: 2) do
          [tier_str, filter_str] ->
            bucket = {safe_atom(tier_str) || :primary, parse_filter(filter_str)}
            Map.put(acc, bucket, normalise_sticky(raw))

          _ ->
            acc
        end
      end)
    else
      _ -> %{}
    end
  end

  defp normalise_sticky(map) when is_map(map) do
    %{
      provider_name: Map.get(map, "provider_name") || Map.get(map, :provider_name),
      model_id: Map.get(map, "model_id") || Map.get(map, :model_id),
      canonical_id: Map.get(map, "canonical_id") || Map.get(map, :canonical_id),
      set_at: Map.get(map, "set_at") || Map.get(map, :set_at) || 0
    }
  end

  defp parse_filter(""), do: nil
  defp parse_filter(str), do: safe_atom(str)

  # ----- health persistence -----

  defp schedule_flush(%{flush_pending?: true} = state), do: state

  defp schedule_flush(state) do
    Process.send_after(self(), :flush_health, @flush_debounce_ms)
    %{state | flush_pending?: true}
  end

  defp flush_health_to_disk do
    entries =
      @health_table
      |> :ets.tab2list()
      |> Map.new(fn {model_id, health} -> {model_id, health} end)

    File.mkdir_p!(Path.dirname(@health_path))

    case Jason.encode(entries) do
      {:ok, json} ->
        File.write(@health_path, json)

      {:error, reason} ->
        Logger.warning("ModelRouter: failed to encode health snapshot: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("ModelRouter: failed to flush health: #{Exception.message(e)}")
  end

  defp load_health_from_disk do
    with {:ok, body} <- File.read(@health_path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      Enum.each(decoded, fn {model_id, raw} ->
        :ets.insert(@health_table, {model_id, normalise_health(raw)})
      end)

      Logger.debug("ModelRouter: loaded health for #{map_size(decoded)} routes from #{@health_path}")
    else
      {:error, :enoent} ->
        :ok

      other ->
        Logger.warning("ModelRouter: skipping malformed health file: #{inspect(other)}")
    end
  end

  defp normalise_health(map) when is_map(map) do
    Map.merge(default_health(), %{
      error_count: get_int(map, ["error_count", :error_count], 0),
      cooldown_until: get_int(map, ["cooldown_until", :cooldown_until]),
      last_success_at: get_int(map, ["last_success_at", :last_success_at]),
      last_error_at: get_int(map, ["last_error_at", :last_error_at]),
      last_error_kind: get_atom(map, ["last_error_kind", :last_error_kind]),
      consecutive_successes: get_int(map, ["consecutive_successes", :consecutive_successes], 0),
      verified_at: get_int(map, ["verified_at", :verified_at])
    })
  end

  defp get_int(map, keys, default \\ nil) do
    Enum.find_value(keys, default, fn k ->
      case Map.get(map, k) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
  end

  defp get_atom(map, keys) do
    Enum.find_value(keys, nil, fn k ->
      case Map.get(map, k) do
        a when is_atom(a) -> a
        s when is_binary(s) -> safe_atom(s)
        _ -> nil
      end
    end)
  end

  defp safe_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

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
      if ctx.tools == [] do
        parts
      else
        tool_names = Enum.map_join(ctx.tools, ", ", & &1["name"])
        ["Available tools: #{tool_names}" | parts]
      end

    parts =
      if ctx.mode do
        ["Mode: #{ctx.mode}" | parts]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  defp filter_routes(routes, :free_only) do
    Enum.filter(routes, fn route ->
      MapSet.member?(route.capabilities, :free)
    end)
  end

  defp filter_routes(routes, nil), do: routes
  defp filter_routes(routes, _), do: routes
end
