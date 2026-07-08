defmodule Agentic.LLM.Gateway do
  @moduledoc """
  Transparent LLM API proxy that sits between external coding agents
  (Claude Code, OpenCode, Codex, Kimi, etc.) and the actual LLM providers.

  Provides functions that can be called from a web layer (e.g. a Phoenix
  controller or Plug) to forward Anthropic/OpenAI-format requests,
  capture full traffic details, and emit `:agentic` telemetry events
  that flow into Worth's X-Ray panel.

  ## Usage (from web controller)

      {status, headers, body} = Agentic.LLM.Gateway.proxy(
        :anthropic,
        "POST",
        "/v1/messages",
        req_headers,
        req_body
      )

  ## Environment injection for coding agents

  The gateway exposes `base_url/1` so coding-agent protocols can inject
  the proxy endpoint into spawned CLI processes:

      config
      |> put_in([:env, "ANTHROPIC_BASE_URL"], Agentic.LLM.Gateway.base_url(:anthropic))

  """

  alias Agentic.LLM.{Credentials, ProviderRegistry, Response}

  require Logger

  @typedoc "Provider atom that the gateway knows how to proxy."
  @type provider_id :: :anthropic | :openai | atom()

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Returns the local gateway base URL for a provider shape.
  The host application (Worth) is expected to mount the gateway
  routes and tell us the public port/path.
  """
  @spec base_url(provider_id()) :: String.t() | nil
  def base_url(provider_id) do
    case Application.get_env(:agentic, :llm_gateway_base_url) do
      nil -> nil
      base -> "#{String.trim_trailing(base, "/")}/#{provider_path(provider_id)}"
    end
  end

  @doc """
  Injects gateway environment variables into a coding agent's env map.

  Only injects when (1) a gateway base URL is configured and (2) credentials
  are actually resolvable for the provider. Without credentials the gateway
  would 401 every request, so we leave the CLI to use its own auth (e.g.
  Claude Code's OAuth session) by talking to the real provider directly.
  """
  @spec inject_env(map(), provider_id()) :: map()
  def inject_env(env_map, provider_id) do
    with url when is_binary(url) <- base_url(provider_id),
         true <- provider_configured?(provider_id) do
      Map.put(env_map, env_var_name(provider_id), url)
    else
      _ -> env_map
    end
  end

  defp provider_configured?(provider_id) do
    case resolve_provider_safe(provider_id) do
      nil ->
        false

      provider ->
        match?({:ok, _}, Credentials.resolve(provider))
    end
  end

  defp resolve_provider_safe(provider_id) do
    resolve_provider(provider_id)
  rescue
    _ -> nil
  end

  defp env_var_name(:anthropic), do: "ANTHROPIC_BASE_URL"
  defp env_var_name(:openai), do: "OPENAI_BASE_URL"
  defp env_var_name(_), do: "OPENAI_BASE_URL"

  @doc """
  Proxy a request to the real provider.

  Returns `{status_code, response_headers, response_body}` where
  `response_body` is an *enumerable* of chunks for streaming responses
  or a plain string/binary for non-streaming ones.
  """
  @spec proxy(provider_id(), String.t(), [{String.t(), String.t()}], map() | binary()) ::
          {integer(), [{String.t(), String.t()}], Enumerable.t() | binary()}
  def proxy(provider_id, path, headers, body) do
    start_time = System.monotonic_time()
    call_id = generate_call_id()

    provider = resolve_provider(provider_id)
    parsed_body = parse_body(body)
    stream? = Map.get(parsed_body, "stream", false)

    emit_gateway_start(call_id, provider_id, path, parsed_body, stream?)

    result =
      if stream? do
        proxy_stream(provider, path, headers, parsed_body, call_id, start_time)
      else
        proxy_sync(provider, path, headers, parsed_body, call_id, start_time)
      end

    result
  end

  # ── Internal proxy implementations ──────────────────────────────

  defp proxy_sync(provider, _path, req_headers, body, call_id, start_time) do
    case Credentials.resolve(provider) do
      {:ok, creds} ->
        transport_mod = provider.transport()
        base_url = creds.base_url_override || provider.default_base_url()

        # Build the canonical params from the raw request body
        canonical = body_to_canonical(body)

        request =
          transport_mod.build_chat_request(canonical,
            base_url: base_url,
            api_key: creds.api_key,
            extra_headers: creds.headers ++ filter_headers(req_headers)
          )

        case Req.post(request.url,
               json: request.body,
               headers: request.headers,
               receive_timeout: Agentic.LLM.Timeout.receive_timeout()
             ) do
          {:ok, %{status: status, body: resp_body, headers: resp_headers}} ->
            duration = System.monotonic_time() - start_time

            {_parsed, usage} =
              case transport_mod.parse_chat_response(status, resp_body, resp_headers) do
                {:ok, %Response{} = r} ->
                  {r, r.usage}

                {:error, err} ->
                  {%{error: err.message}, %{}}
              end

            emit_gateway_stop(call_id, provider.id(), status, duration, usage, resp_body)

            resp_headers = normalize_headers(resp_headers)
            {status, resp_headers, Jason.encode!(resp_body)}

          {:error, exception} ->
            duration = System.monotonic_time() - start_time

            emit_gateway_stop(call_id, provider.id(), nil, duration, %{}, %{
              error: inspect(exception)
            })

            {502, [{"content-type", "application/json"}],
             Jason.encode!(%{
               error: %{message: Exception.message(exception), type: "gateway_error"}
             })}
        end

      :not_configured ->
        duration = System.monotonic_time() - start_time
        emit_gateway_stop(call_id, provider.id(), 401, duration, %{}, %{})

        {401, [{"content-type", "application/json"}],
         Jason.encode!(%{error: %{message: "Provider not configured", type: "auth_error"}})}
    end
  end

  defp proxy_stream(provider, _path, req_headers, body, call_id, start_time) do
    case Credentials.resolve(provider) do
      {:ok, creds} ->
        transport_mod = provider.transport()
        base_url = creds.base_url_override || provider.default_base_url()
        canonical = body_to_canonical(body)

        request =
          transport_mod.build_chat_request(canonical,
            base_url: base_url,
            api_key: creds.api_key,
            extra_headers: creds.headers ++ filter_headers(req_headers)
          )

        req_body = Map.put(request.body, :stream, true)

        case Req.request(
               method: :post,
               url: request.url,
               json: req_body,
               headers: request.headers,
               receive_timeout: Agentic.LLM.Timeout.receive_timeout(),
               into: :self
             ) do
          {:ok, %{status: 200, body: %Req.Response.Async{} = async_body, headers: resp_headers}} ->
            first_chunk_time = ref(:none)
            chunk_count = ref(0)

            on_done = fn ->
              duration = System.monotonic_time() - start_time

              ttft_ms =
                case get(first_chunk_time) do
                  :none -> nil
                  t -> System.convert_time_unit(t - start_time, :native, :millisecond)
                end

              emit_gateway_stream_stop(
                call_id,
                provider.id(),
                200,
                duration,
                %{},
                get(chunk_count),
                ttft_ms,
                %{}
              )
            end

            wrapped = %Agentic.LLM.Gateway.AsyncStream{
              async: async_body,
              on_chunk: fn ->
                bump(chunk_count)

                if compare_and_set(first_chunk_time, :none, System.monotonic_time()) do
                  :ok
                end
              end,
              on_done: on_done
            }

            wrapped_stream = Stream.concat([wrapped], [build_sse_done()])

            resp_headers = normalize_headers(resp_headers)

            {200,
             [
               {"content-type", "text/event-stream"},
               {"cache-control", "no-cache"} | resp_headers
             ], wrapped_stream}

          {:ok, %{status: status, body: resp_body, headers: resp_headers}}
          when is_binary(resp_body) or is_map(resp_body) ->
            duration = System.monotonic_time() - start_time

            emit_gateway_stream_stop(
              call_id,
              provider.id(),
              status,
              duration,
              %{},
              0,
              nil,
              resp_body
            )

            resp_headers = normalize_headers(resp_headers)
            {status, resp_headers, Jason.encode!(resp_body)}

          {:error, exception} ->
            duration = System.monotonic_time() - start_time

            emit_gateway_stream_stop(call_id, provider.id(), 502, duration, %{}, 0, nil, %{
              error: inspect(exception)
            })

            {502, [{"content-type", "application/json"}],
             Jason.encode!(%{
               error: %{message: Exception.message(exception), type: "gateway_error"}
             })}
        end

      :not_configured ->
        duration = System.monotonic_time() - start_time
        emit_gateway_stream_stop(call_id, provider.id(), 401, duration, %{}, 0, nil, %{})

        {401, [{"content-type", "application/json"}],
         Jason.encode!(%{error: %{message: "Provider not configured", type: "auth_error"}})}
    end
  end

  # ── Body translation ────────────────────────────────────────────

  # Anthropic Messages API body -> canonical params
  defp body_to_canonical(%{"model" => model, "messages" => messages} = body) do
    %{
      model: model,
      messages: Enum.map(messages, &normalize_message/1),
      system: body["system"],
      tools: body["tools"] || [],
      max_tokens: body["max_tokens"],
      temperature: body["temperature"],
      tool_choice: body["tool_choice"],
      cache_control: nil
    }
  end

  # OpenAI Chat Completions API body -> canonical params
  defp body_to_canonical(%{"model" => model} = body) do
    messages = body["messages"] || []

    system =
      case List.first(messages) do
        %{"role" => "system", "content" => content} -> content
        _ -> nil
      end

    %{
      model: model,
      messages: Enum.map(messages, &normalize_message/1),
      system: system,
      tools: body["tools"] || [],
      max_tokens: body["max_tokens"],
      temperature: body["temperature"],
      tool_choice: body["tool_choice"],
      cache_control: nil
    }
  end

  defp body_to_canonical(body) when is_map(body) do
    %{
      model: body["model"] || "unknown",
      messages: [],
      system: nil,
      tools: [],
      max_tokens: nil,
      temperature: nil,
      tool_choice: nil,
      cache_control: nil
    }
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{"role" => role, "content" => content}
  end

  defp normalize_message(other), do: other

  # ── Helpers ─────────────────────────────────────────────────────

  defp resolve_provider(:anthropic), do: ProviderRegistry.get(:anthropic)
  defp resolve_provider(:openai), do: ProviderRegistry.get(:openai)

  defp resolve_provider(provider_id) when is_atom(provider_id) do
    ProviderRegistry.get(provider_id) || ProviderRegistry.get(:openai)
  end

  defp provider_path(:anthropic), do: "anthropic"
  defp provider_path(:openai), do: "openai"
  defp provider_path(id), do: to_string(id)

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_body(body) when is_map(body), do: body
  defp parse_body(_), do: %{}

  defp filter_headers(headers) do
    # Pass through headers that are not host-specific or auth-related
    # The provider transport will inject its own auth
    Enum.reject(headers, fn {k, _} ->
      down = String.downcase(k)
      down in ["host", "content-length", "connection"]
    end)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn
      {k, [v | _]} -> {k, v}
      {k, v} when is_binary(v) -> {k, v}
    end)
    |> Enum.filter(fn {k, _} -> is_binary(k) end)
  end

  defp build_sse_done, do: "data: [DONE]\n\n"

  # ── Telemetry ───────────────────────────────────────────────────

  defp emit_gateway_start(call_id, provider_id, path, body, stream?) do
    Agentic.Telemetry.event(
      [:gateway, :request, :start],
      %{timestamp: System.system_time(:millisecond)},
      %{
        call_id: call_id,
        provider: provider_id,
        path: path,
        model: body["model"],
        stream: stream?,
        messages: summarize_messages(body["messages"]),
        tools: tool_names(body["tools"]),
        system_preview: system_preview(body["system"])
      }
    )
  end

  defp emit_gateway_stop(call_id, provider_id, status, duration, usage, raw_response) do
    # Feed every attempt's wall time to the adaptive timeout so it self-tunes to
    # the provider's real latency (a run of :timeouts ratchets it up; fast calls
    # let it settle). Native → ms; the tracker guards non-positive values.
    Agentic.LLM.Timeout.observe(System.convert_time_unit(duration, :native, :millisecond))

    {actual_cost, estimated_cost} = extract_costs(provider_id, raw_response, usage)

    Agentic.Telemetry.event(
      [:gateway, :request, :stop],
      %{
        duration: duration,
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        cache_read: usage[:cache_read] || 0,
        cache_write: usage[:cache_write] || 0
      },
      %{
        call_id: call_id,
        provider: provider_id,
        status: status,
        actual_cost: actual_cost,
        estimated_cost: estimated_cost,
        raw_response: truncate_raw(raw_response)
      }
    )
  end

  defp emit_gateway_stream_stop(
         call_id,
         provider_id,
         status,
         duration,
         usage,
         chunk_count,
         ttft_ms,
         final_acc
       ) do
    {actual_cost, estimated_cost} = extract_costs(provider_id, final_acc, usage)

    Agentic.Telemetry.event(
      [:gateway, :request, :stop],
      %{
        duration: duration,
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        cache_read: usage[:cache_read] || 0,
        cache_write: usage[:cache_write] || 0
      },
      %{
        call_id: call_id,
        provider: provider_id,
        status: status,
        stream: true,
        chunk_count: chunk_count,
        ttft_ms: ttft_ms,
        actual_cost: actual_cost,
        estimated_cost: estimated_cost,
        raw_response: truncate_raw(final_acc)
      }
    )
  end

  # ── Cost extraction ─────────────────────────────────────────────

  # Returns `{actual_cost, estimated_cost}` as `Money.t() | nil` pairs.
  # `actual_cost` is the provider-reported value (currently only OpenRouter
  # returns `usage.cost`); `estimated_cost` is computed from catalog
  # pricing so we always have a number even when the provider doesn't
  # bill us per response.
  defp extract_costs(provider_id, raw_response, usage) do
    actual = actual_cost_from_response(provider_id, raw_response)
    estimated = estimated_cost_from_usage(provider_id, raw_response, usage)
    {actual, estimated}
  end

  defp actual_cost_from_response(:openrouter, %{"usage" => %{"cost" => n}}) when is_number(n) do
    Money.from_float(:USD, n)
  rescue
    _ -> nil
  end

  defp actual_cost_from_response(_provider_id, _body), do: nil

  defp estimated_cost_from_usage(provider_id, raw_response, usage) do
    model_id = response_model_id(raw_response)
    input_tokens = usage[:input_tokens] || 0
    output_tokens = usage[:output_tokens] || 0
    cache_read = usage[:cache_read] || 0
    cache_write = usage[:cache_write] || 0

    with model_id when is_binary(model_id) <- model_id,
         %Agentic.LLM.Model{cost: %{input: ip, output: op} = cost} when not is_nil(cost) <-
           Agentic.LLM.Catalog.lookup(provider_id, model_id) do
      cache_read_rate = cost[:cache_read] || 0.0
      cache_write_rate = cost[:cache_write] || 0.0

      total =
        input_tokens / 1_000_000 * ip +
          output_tokens / 1_000_000 * op +
          cache_read / 1_000_000 * cache_read_rate +
          cache_write / 1_000_000 * cache_write_rate

      if total > 0, do: Money.from_float(:USD, total), else: nil
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp response_model_id(%{"model" => model}) when is_binary(model), do: model
  defp response_model_id(_), do: nil

  defp summarize_messages(nil), do: []

  defp summarize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn %{"role" => role, "content" => content} ->
      %{role: role, preview: truncate_str(to_string(content), 150)}
    end)
  end

  defp summarize_messages(_), do: []

  defp tool_names(nil), do: []
  defp tool_names(tools) when is_list(tools), do: Enum.map(tools, &(&1["name"] || "?"))
  defp tool_names(_), do: []

  defp system_preview(nil), do: nil
  defp system_preview(text) when is_binary(text), do: truncate_str(text, 200)
  defp system_preview(list) when is_list(list), do: truncate_str(inspect(list), 200)
  defp system_preview(_), do: nil

  defp truncate_raw(nil), do: nil
  defp truncate_raw(body) when is_map(body), do: body |> Jason.encode!() |> truncate_str(600)
  defp truncate_raw(body) when is_binary(body), do: truncate_str(body, 600)
  defp truncate_raw(body), do: truncate_str(inspect(body, limit: 300), 600)

  defp truncate_str(str, max) when is_binary(str) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "…", else: str
  end

  # ── Atomic refs for TTFT tracking ───────────────────────────────

  defp ref(initial),
    do: :atomics.new(1, signed: false) |> tap(&:atomics.put(&1, 1, encode_ref(initial)))

  defp get(ref), do: :atomics.get(ref, 1) |> decode_ref()
  defp bump(ref), do: :atomics.add(ref, 1, 1)

  defp compare_and_set(ref, expected, value) do
    current = get(ref)

    if current == expected do
      :atomics.put(ref, 1, encode_ref(value))
      true
    else
      false
    end
  end

  defp encode_ref(:none), do: 0
  defp encode_ref(n) when is_integer(n) and n > 0, do: n + 1
  defp decode_ref(0), do: :none
  defp decode_ref(n) when is_integer(n) and n > 0, do: n - 1

  defp generate_call_id do
    "gw-#{System.monotonic_time()}-#{:erlang.unique_integer([:positive])}"
  end
end
