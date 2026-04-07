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

  alias AgentEx.Loop.Context
  alias AgentEx.ModelRouter

  require Logger

  @impl true
  def model_tier, do: :primary

  @impl true
  def call(%Context{} = ctx, next) do
    tier = ctx.model_tier || :primary

    Logger.debug(
      "LLMCall: turn #{ctx.turns_used + 1}/#{ctx.config.max_turns} for #{ctx.session_id} (tier: #{tier})"
    )

    {stable_prefix, _volatile_suffix} = split_messages(ctx.messages)
    stable_hash = compute_stable_hash(stable_prefix, ctx.tools)
    prefix_changed = ctx.stable_prefix_hash != stable_hash

    route = resolve_route(tier)

    params = %{
      "messages" => ctx.messages,
      "tools" => ctx.tools,
      "session_id" => ctx.session_id,
      "user_id" => ctx.user_id,
      "model_tier" => to_string(tier),
      "cache_control" => %{
        "stable_hash" => stable_hash,
        "prefix_changed" => prefix_changed
      },
      "_route" => route
    }

    llm_chat = ctx.callbacks[:llm_chat] || fn _ -> {:error, :no_llm_adapter} end
    start_time = System.monotonic_time()

    result =
      case llm_chat.(params) do
        {:ok, response} = ok ->
          if route do
            ModelRouter.report_success(route.provider_name, route.model_id)
          end

          ok

        {:error, _} = err ->
          if route do
            ModelRouter.report_error(route.provider_name, route.model_id, classify_error(err))
          end

          err
      end

    case result do
      {:ok, response} ->
        duration = System.monotonic_time() - start_time
        telemetry_prefix = ctx.config[:telemetry_prefix] || [:agent_ex]

        try do
          usage = response["usage"] || %{}

          :telemetry.execute(
            telemetry_prefix ++ [:llm_call, :stop],
            %{
              duration: duration,
              input_tokens: usage["input_tokens"] || 0,
              output_tokens: usage["output_tokens"] || 0,
              cost_usd: response["cost"] || 0.0
            },
            %{model_tier: tier, session_id: ctx.session_id, route: route && route.model_id}
          )
        rescue
          _ -> :ok
        end

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

  defp resolve_route(tier) do
    case ModelRouter.resolve(tier) do
      {:ok, route} ->
        Logger.debug("LLMCall: resolved route #{route.model_id} (source: #{route.source})")
        route

      {:error, reason} ->
        Logger.warning(
          "LLMCall: route resolution failed: #{inspect(reason)}, proceeding without route"
        )

        nil
    end
  rescue
    e ->
      Logger.warning("LLMCall: route resolution crashed: #{Exception.message(e)}")
      nil
  end

  defp classify_error({:error, reason}) do
    reason_str = to_string(reason)

    cond do
      String.contains?(reason_str, "rate") or String.contains?(reason_str, "429") ->
        :rate_limit

      String.contains?(reason_str, "401") or String.contains?(reason_str, "403") or
          String.contains?(reason_str, "unauthorized") ->
        :auth_error

      String.contains?(reason_str, "connection") or String.contains?(reason_str, "timeout") ->
        :connection_error

      true ->
        :other
    end
  end

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
