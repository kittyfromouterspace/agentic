defmodule Agentic.LLM.Provider.OpenRouter do
  @moduledoc """
  OpenRouter provider.

  Uses `Agentic.LLM.Transport.OpenAIChatCompletions` transport with
  OpenRouter-specific base URL and analytics headers. Supports
  dynamic catalog fetching from `/api/v1/models` and per-model
  endpoint discovery from `/api/v1/models/{id}/endpoints`.
  """

  @behaviour Agentic.LLM.Provider

  alias Agentic.LLM.Credentials
  alias Agentic.LLM.Model
  alias Agentic.LLM.Usage
  alias Agentic.LLM.UsageWindow

  @default_base_url "https://openrouter.ai/api/v1"

  # How many models we fetch endpoint data for in parallel.
  # Free models + primary-tier models get endpoint details.
  @endpoint_fetch_concurrency 15
  @endpoint_fetch_timeout_ms 12_000

  @impl true
  def id, do: :openrouter

  @impl true
  def label, do: "OpenRouter"

  @impl true
  def transport, do: Agentic.LLM.Transport.OpenAIChatCompletions

  @impl true
  def default_base_url, do: @default_base_url

  @impl true
  def env_vars, do: ["OPENROUTER_API_KEY"]

  @impl true
  def supports, do: MapSet.new([:chat, :tools, :vision, :embeddings])

  @impl true
  def request_headers(%Credentials{} = _creds) do
    [
      {"HTTP-Referer", "https://github.com/lenzg/worth"},
      {"X-Title", "worth"}
    ]
  end

  # Build the OpenRouter-specific `provider` object for the request body.
  #
  # When `canonical[:preference]` is present we map it to OpenRouter's
  # `sort` field so the provider can route to the best endpoint in real
  # time:
  #
  #   * `:optimize_price`  → "price"
  #   * `:optimize_speed`  → "throughput"
  #
  # `data_collection: "allow"` is required for free-tier endpoints.
  # `allow_fallbacks: true` lets OpenRouter try alternate providers.
  @impl true
  def request_body_extras(canonical) do
    preference = canonical[:preference]

    sort =
      case preference do
        :optimize_price -> "price"
        :optimize_speed -> "throughput"
        _ -> nil
      end

    provider = %{
      "data_collection" => "allow",
      "allow_fallbacks" => true
    }

    provider = if sort, do: Map.put(provider, "sort", sort), else: provider

    %{"provider" => provider}
  end

  @impl true
  def default_models do
    [
      %Model{
        id: "minimax/minimax-m2.5:free",
        provider: :openrouter,
        label: "MiniMax M2.5 Free (via OpenRouter)",
        context_window: 1_000_000,
        max_output_tokens: 16_384,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:chat, :tools, :free]),
        tier_hint: :primary,
        source: :static
      }
    ]
  end

  @impl true
  def fetch_catalog(%Credentials{api_key: api_key} = _creds)
      when is_binary(api_key) and api_key != "" do
    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    with {:ok, chat_models} <- fetch_models("#{@default_base_url}/models", headers) do
      embedding_models =
        case fetch_models("#{@default_base_url}/models?output_modalities=embeddings", headers) do
          {:ok, models} ->
            Enum.map(models, fn m ->
              %{m | capabilities: MapSet.put(m.capabilities, :embeddings)}
            end)

          {:error, reason} ->
            require Logger

            Logger.warning("OpenRouter embedding catalog fetch failed: #{inspect(reason)}")
            []
        end

      merged = Enum.uniq_by(chat_models ++ embedding_models, & &1.id)

      # Fetch endpoint details for models we care about:
      # free models + primary-tier chat models.
      endpoint_models =
        merged
        |> Enum.filter(fn m ->
          MapSet.member?(m.capabilities, :free) or m.tier_hint == :primary
        end)

      endpoints_by_id = fetch_endpoints(endpoint_models, headers)

      models_with_endpoints =
        Enum.map(merged, fn m ->
          case Map.get(endpoints_by_id, m.id) do
            nil -> m
            eps -> %{m | endpoints: eps}
          end
        end)

      {:ok, models_with_endpoints}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def fetch_catalog(_), do: :not_supported

  defp fetch_models(url, headers) do
    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        parsed =
          models
          |> Enum.map(&parse_model/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fetch `/endpoints` for a batch of models in parallel.
  # Returns a map of `model_id => [endpoint_maps]`.
  defp fetch_endpoints(models, headers) do
    models
    |> Task.async_stream(
      fn %Model{id: id} ->
        case Req.get(
               "#{@default_base_url}/models/#{URI.encode_www_form(id)}/endpoints",
               headers: headers,
               receive_timeout: @endpoint_fetch_timeout_ms
             ) do
          {:ok, %{status: 200, body: %{"data" => %{"endpoints" => endpoints}}}} ->
            {id, normalize_endpoints(endpoints)}

          {:ok, %{status: 200, body: %{"data" => data}}} when is_map(data) ->
            {id, normalize_endpoints(data["endpoints"] || [])}

          {:ok, %{status: status}} ->
            require Logger
            Logger.debug("OpenRouter endpoints #{id}: HTTP #{status}")
            {id, nil}

          {:error, reason} ->
            require Logger
            Logger.debug("OpenRouter endpoints #{id}: #{inspect(reason)}")
            {id, nil}
        end
      end,
      max_concurrency: @endpoint_fetch_concurrency,
      timeout: @endpoint_fetch_timeout_ms + 2_000,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, endpoints}}, acc ->
        if is_list(endpoints), do: Map.put(acc, id, endpoints), else: acc

      _, acc ->
        acc
    end)
  end

  # Normalize endpoint data into a flat, predictable shape.
  defp normalize_endpoints(endpoints) when is_list(endpoints) do
    Enum.map(endpoints, fn ep ->
      %{
        provider_name: ep["provider_name"],
        pricing: ep["pricing"],
        status: ep["status"],
        uptime_last_30m: ep["uptime_last_30m"],
        uptime_last_5m: ep["uptime_last_5m"],
        uptime_last_1d: ep["uptime_last_1d"],
        latency_last_30m: ep["latency_last_30m"],
        throughput_last_30m: ep["throughput_last_30m"],
        max_completion_tokens: ep["max_completion_tokens"],
        quantization: ep["quantization"],
        supports_implicit_caching: ep["supports_implicit_caching"]
      }
    end)
  end

  defp normalize_endpoints(_), do: []

  @impl true
  def fetch_usage(%Credentials{api_key: api_key} = _creds)
      when is_binary(api_key) and api_key != "" do
    url = "#{@default_base_url}/auth/key"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_map(data) ->
        {:ok, parse_usage(data)}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, parse_usage(body)}

      _ ->
        :not_supported
    end
  rescue
    _ -> :not_supported
  end

  def fetch_usage(_), do: :not_supported

  @impl true
  def classify_http_error(_status, _body, _headers), do: :default

  defp parse_usage(data) do
    used = (data["usage"] || 0.0) / 1.0
    limit = data["limit"]

    credits =
      if is_number(limit) do
        %{used: used, limit: limit / 1.0}
      end

    windows =
      case data["rate_limit"] do
        %{"requests" => requests, "interval" => interval} when is_number(requests) ->
          [
            %UsageWindow{
              label: "rate (#{interval})",
              limit: requests / 1.0,
              unit: :requests
            }
          ]

        _ ->
          []
      end

    %Usage{
      provider: :openrouter,
      label: "OpenRouter",
      plan: data["label"],
      windows: windows,
      credits: credits,
      fetched_at: System.system_time(:millisecond)
    }
  end

  # Test hook: exposes the catalog-row parser so the capability-tagging
  # logic can be exercised directly without stubbing HTTP.
  @doc false
  def __parse_model__(raw), do: parse_model(raw)

  # Tags a model with semantic capabilities derived from OpenRouter's
  # catalog metadata. The intent: a model only carries `:chat` when it is
  # genuinely conversational (text-in, text-out, not a specialty output).
  # Vision/audio/image-gen/embedding specialists carry only their modality
  # tag so the manual-tier router never picks them for plain conversation.
  defp parse_model(raw) do
    id = raw["id"]
    context = raw["context_length"]
    pricing = raw["pricing"] || %{}
    params = raw["supported_parameters"] || []
    inputs = get_in(raw, ["architecture", "input_modalities"]) || []
    outputs = get_in(raw, ["architecture", "output_modalities"]) || []

    prompt_price = parse_price(pricing["prompt"])
    completion_price = parse_price(pricing["completion"])

    text_in? = "text" in inputs
    text_out? = "text" in outputs
    image_in? = "image" in inputs
    image_out? = "image" in outputs
    audio_in? = "audio" in inputs
    audio_out? = "audio" in outputs
    embeddings? = "embeddings" in outputs

    # A "conversational" model produces text from text. Image-only,
    # audio-only, image-gen, or embedding-only models do not get :chat.
    chat? = text_in? and text_out? and not (image_out? or audio_out? or embeddings?)
    tools? = "tools" in params and chat?

    capabilities =
      []
      |> add_if(tools?, :tools)
      |> add_if(chat?, :chat)
      |> add_if(image_in?, :vision)
      |> add_if(audio_in?, :audio_in)
      |> add_if(audio_out?, :audio_out)
      |> add_if(image_out?, :image_gen)
      |> add_if(embeddings?, :embeddings)
      |> add_if("reasoning" in params, :reasoning)
      |> add_if(prompt_price == 0.0 and completion_price == 0.0, :free)
      |> MapSet.new()

    # Only true conversational + tool-using models earn a tier hint.
    # Specialty models stay at `nil` so the manual router never offers
    # them as a primary candidate; auto-mode + capability-aware callers
    # can still target them via `Catalog.find(has: [:vision])` etc.
    tier_hint =
      cond do
        not (chat? and tools?) -> nil
        is_integer(context) and context >= 64_000 -> :primary
        is_integer(context) and context >= 8_000 -> :lightweight
        true -> nil
      end

    %Model{
      id: id,
      provider: :openrouter,
      label: raw["name"] || id,
      context_window: context,
      max_output_tokens: get_in(raw, ["top_provider", "max_completion_tokens"]),
      cost: %{input: prompt_price, output: completion_price},
      capabilities: capabilities,
      tier_hint: tier_hint,
      source: :discovered
    }
  end

  defp add_if(caps, true, tag), do: [tag | caps]
  defp add_if(caps, _false, _tag), do: caps

  defp parse_price(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_price(_), do: 0.0
end
