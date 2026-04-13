defmodule AgentEx.Loop.Stages.LLMCall do
  @moduledoc """
  Makes the LLM API call and stores the response in context.

  Uses the `llm_chat` callback from `ctx.callbacks` to make the actual API call.
  The response is stored in `ctx.last_response` for the next stage
  (typically ModeRouter) to process.

  ## Model Routing

  Resolves the best model route via `AgentEx.ModelRouter` before each call.
  The resolved route is passed to the callback under `"_route"` key.
  If routing fails, falls back to direct callback invocation.

  ## Cache Awareness (V1.2)

  Separates params into a stable prefix (system prompt, workspace snapshot,
  tool definitions) and volatile suffix (recent transcript). Computes a
  `stable_prefix_hash` so the host can detect when the prefix changed and
  pass cache boundary hints to the LLM provider.

  The params map sent to `llm_chat` includes a `"cache_control"` key with:
  - `"stable_hash"` — hash of the stable prefix content
  - `"prefix_changed"` — boolean, true when prefix differs from last call
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context
  alias AgentEx.ModelRouter

  require Logger

  @impl true
  def model_tier, do: :primary

  @impl true
  def call(%Context{} = ctx, next) do
    tier = ctx.model_tier || :primary
    selection_mode = Map.get(ctx, :model_selection_mode, :manual)

    Logger.debug(
      "LLMCall: turn #{ctx.turns_used + 1}/#{ctx.config.max_turns} for #{ctx.session_id} (mode: #{selection_mode}, tier: #{tier})"
    )

    AgentEx.Telemetry.event([:llm_call, :start], %{}, %{
      session_id: ctx.session_id,
      model_selection_mode: selection_mode,
      model_tier: tier
    })

    {stable_prefix, _volatile_suffix} = split_messages(ctx.messages)
    stable_hash = compute_stable_hash(stable_prefix, ctx.tools)
    prefix_changed = ctx.stable_prefix_hash != stable_hash

    base_params = %{
      "messages" => ctx.messages,
      "tools" => ctx.tools,
      "session_id" => ctx.session_id,
      "user_id" => ctx.user_id,
      "model_tier" => to_string(tier),
      "cache_control" => %{
        "stable_hash" => stable_hash,
        "prefix_changed" => prefix_changed
      }
    }

    llm_chat = ctx.callbacks[:llm_chat] || fn _ -> {:error, :no_llm_adapter} end
    start_time = System.monotonic_time()

    {result, used_route} =
      case selection_mode do
        :auto -> try_auto_routes(ctx, base_params, llm_chat)
        _ -> try_routes_for_tier(tier, base_params, llm_chat, ctx)
      end

    case result do
      {:ok, response} ->
        duration = System.monotonic_time() - start_time
        usage = response.usage

        input_tokens = usage.input_tokens
        output_tokens = usage.output_tokens
        cache_read = usage.cache_read
        cache_write = usage.cache_write

        cost_usd =
          response.cost ||
            compute_cost(used_route, %{
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              cache_read: cache_read,
              cache_write: cache_write
            })

        response = %{response | cost: cost_usd}

        AgentEx.Telemetry.event(
          [:llm_call, :stop],
          %{
            duration: duration,
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_read: cache_read,
            cache_write: cache_write,
            cost_usd: cost_usd
          },
          %{
            model_tier: tier,
            model_selection_mode: selection_mode,
            session_id: ctx.session_id,
            route: used_route && used_route[:model_id],
            provider: used_route && used_route[:provider_name]
          }
        )

        ctx = Context.track_usage(ctx, response)

        ctx = %{
          ctx
          | last_response: response,
            turns_used: ctx.turns_used + 1,
            stable_prefix_hash: stable_hash
        }

        next.(ctx)

      {:error, reason} ->
        Logger.error("LLMCall failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Compute USD cost from a route + token usage by looking the model
  # up in the catalog. Returns 0.0 when the route, model, or pricing
  # is unknown — telemetry stays well-formed.
  defp compute_cost(nil, _usage), do: 0.0

  defp compute_cost(route, usage) when is_map(route) do
    cost = route[:cost] || (route_model(route) || %{})[:cost]

    case cost do
      %{} = cost ->
        in_per = (usage.input_tokens || 0) / 1_000_000
        out_per = (usage.output_tokens || 0) / 1_000_000
        cache_read_per = (usage.cache_read || 0) / 1_000_000
        cache_write_per = (usage.cache_write || 0) / 1_000_000

        (cost[:input] || cost["input"] || 0.0) * in_per +
          (cost[:output] || cost["output"] || 0.0) * out_per +
          (cost[:cache_read] || cost["cache_read"] || 0.0) * cache_read_per +
          (cost[:cache_write] || cost["cache_write"] || 0.0) * cache_write_per

      _ ->
        0.0
    end
  end

  defp compute_cost(_, _), do: 0.0

  defp route_model(%{provider_name: name, model_id: id}) when is_binary(name) and is_binary(id) do
    AgentEx.LLM.Catalog.lookup(safe_atom(name), id)
  end

  defp route_model(_), do: nil

  defp safe_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp try_auto_routes(ctx, base_params, llm_chat) do
    case ModelRouter.resolve_for_context(ctx) do
      {:ok, routes, analysis} when is_list(routes) ->
        if analysis do
          Logger.debug(
            "LLMCall: auto mode selected model (complexity: #{analysis.complexity}, " <>
              "vision: #{analysis.needs_vision}, reasoning: #{analysis.needs_reasoning})"
          )

          AgentEx.Telemetry.event([:model_router, :auto, :selected], %{}, %{
            session_id: ctx.session_id,
            complexity: analysis.complexity,
            needs_vision: analysis.needs_vision,
            needs_audio: analysis.needs_audio,
            needs_reasoning: analysis.needs_reasoning,
            needs_large_context: analysis.needs_large_context,
            estimated_input_tokens: analysis.estimated_input_tokens,
            preference: ctx.model_preference,
            selected_model: (List.first(routes) || %{})[:model_id],
            selected_provider: (List.first(routes) || %{})[:provider_name]
          })
        end

        do_try_routes(routes, :auto, base_params, llm_chat, ctx, nil)

      {:error, reason} ->
        Logger.warning(
          "LLMCall: auto route resolution failed (#{inspect(reason)}), falling back to tier-based"
        )

        AgentEx.Telemetry.event([:model_router, :auto, :fallback], %{}, %{
          session_id: ctx.session_id,
          reason: inspect(reason)
        })

        try_routes_for_tier(ctx.model_tier || :primary, base_params, llm_chat, ctx)
    end
  rescue
    e ->
      Logger.warning(
        "LLMCall: auto route resolution crashed: #{Exception.message(e)}, falling back to tier-based"
      )

      AgentEx.Telemetry.event([:model_router, :auto, :fallback], %{}, %{
        session_id: ctx.session_id,
        reason: Exception.message(e)
      })

      try_routes_for_tier(ctx.model_tier || :primary, base_params, llm_chat, ctx)
  end

  # Walk every healthy route for the tier in priority order. On success
  # we report the route to ModelRouter and stop. On error we classify,
  # report the failure (which puts the route in cooldown if the error
  # threshold is hit), and try the next route. If every route fails we
  # invoke the callback one final time WITHOUT a `_route` so the host's
  # configured-provider fallback (if any) gets a chance.
  defp try_routes_for_tier(tier, base_params, llm_chat, ctx) do
    routes = resolve_routes(tier)
    do_try_routes(routes, tier, base_params, llm_chat, ctx, nil)
  end

  defp do_try_routes([], _tier, base_params, llm_chat, _ctx, last_error) do
    Logger.debug("LLMCall: all routes exhausted, calling callback without _route")
    params = Map.put(base_params, "_route", nil)

    case llm_chat.(params) do
      {:ok, _response} = ok -> {ok, nil}
      {:error, _} = err -> {err, nil}
      _ -> {last_error || {:error, :no_routes_available}, nil}
    end
  end

  defp do_try_routes([route | rest], tier, base_params, llm_chat, ctx, _last) do
    Logger.debug(
      "LLMCall: trying route #{route.provider_name}/#{route.model_id} (source: #{route.source})"
    )

    Context.emit_event(
      ctx,
      {:model_selected,
       %{
         tier: tier,
         model_id: route.model_id,
         provider_name: route.provider_name,
         source: route.source,
         label: Map.get(route, :label, route.model_id)
       }}
    )

    params = Map.put(base_params, "_route", route)

    case llm_chat.(params) do
      {:ok, _response} = ok ->
        ModelRouter.report_success(route.provider_name, route.model_id)
        {ok, route}

      {:error, _reason} = err ->
        failure = classify_error(err)
        retry_after_ms = extract_retry_after(err)

        Logger.warning(
          "LLMCall: route #{route.provider_name}/#{route.model_id} failed (#{failure}, retry_after_ms=#{inspect(retry_after_ms)}); trying next"
        )

        opts = if is_integer(retry_after_ms), do: [retry_after_ms: retry_after_ms], else: []
        ModelRouter.report_error(route.provider_name, route.model_id, failure, opts)
        do_try_routes(rest, tier, base_params, llm_chat, ctx, err)
    end
  end

  defp resolve_routes(tier) do
    case ModelRouter.resolve_all(tier) do
      {:ok, routes} when is_list(routes) ->
        Logger.debug("LLMCall: resolved #{length(routes)} routes for tier #{tier}")
        routes

      other ->
        Logger.warning(
          "LLMCall: resolve_all returned #{inspect(other)}, proceeding without routes"
        )

        []
    end
  rescue
    e ->
      Logger.warning("LLMCall: route resolution crashed: #{Exception.message(e)}")
      []
  end

  # Phase 2: errors carry a structured classification from the
  # ErrorClassifier. We map to the ModelRouter failure-type vocabulary.
  # Legacy string/integer-status shapes still handled as fallback.
  defp classify_error({:error, %{classification: classification}}),
    do: legacy_failure(classification)

  defp classify_error({:error, %{status: 429}}), do: :rate_limit
  defp classify_error({:error, %{status: status}}) when status in [401, 403], do: :auth_error

  defp classify_error({:error, %{status: status}}) when is_integer(status) and status >= 500,
    do: :other

  defp classify_error({:error, %{message: msg}}) when is_binary(msg),
    do: classify_error({:error, msg})

  defp classify_error({:error, reason}) when is_binary(reason) do
    cond do
      String.contains?(reason, "rate") or String.contains?(reason, "429") ->
        :rate_limit

      String.contains?(reason, "401") or String.contains?(reason, "403") or
          String.contains?(reason, "unauthorized") ->
        :auth_error

      String.contains?(reason, "connection") or String.contains?(reason, "timeout") ->
        :connection_error

      true ->
        :other
    end
  end

  defp classify_error(_), do: :other

  defp legacy_failure(:rate_limit), do: :rate_limit
  defp legacy_failure(:overloaded), do: :rate_limit
  defp legacy_failure(:auth), do: :auth_error
  defp legacy_failure(:auth_permanent), do: :auth_error
  defp legacy_failure(:billing), do: :auth_error
  defp legacy_failure(:timeout), do: :connection_error
  defp legacy_failure(:transient), do: :connection_error
  defp legacy_failure(:permanent), do: :other
  defp legacy_failure(:format), do: :other
  defp legacy_failure(:model_not_found), do: :other
  defp legacy_failure(:context_overflow), do: :other
  defp legacy_failure(:session_expired), do: :auth_error
  defp legacy_failure(_), do: :other

  defp extract_retry_after({:error, %{retry_after_ms: ms}}) when is_integer(ms) and ms > 0, do: ms
  defp extract_retry_after(_), do: nil

  defp split_messages(messages) do
    case messages do
      [first | rest] when is_map(first) ->
        stable =
          if first["role"] == "system" do
            [first]
          else
            []
          end

        {stable, rest}

      _ ->
        {[], messages}
    end
  end

  defp compute_stable_hash(stable_prefix, tools) do
    stable_content =
      stable_prefix
      |> Enum.map(fn msg -> Jason.encode!(msg) end)
      |> Enum.join("|")

    tools_content =
      tools
      |> Enum.map(fn tool -> tool["name"] || "" end)
      |> Enum.join(",")

    data = stable_content <> "||" <> tools_content

    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
