defmodule AgentEx.LLM.Provider do
  @moduledoc """
  Behaviour describing one LLM service provider.

  Each provider is a small module that declares which transport it
  uses, points at a base URL, declares env vars for credentials,
  and optionally implements catalog and usage fetchers.

  ## Required callbacks

    * `id/0` — unique atom identifying this provider
    * `label/0` — human-readable name
    * `transport/0` — the transport module to use
    * `default_base_url/0` — base URL for API calls
    * `env_vars/0` — env var names in priority order
    * `default_models/0` — static seed of known models
    * `request_headers/1` — extra headers given resolved credentials
    * `supports/0` — MapSet of capability atoms

  ## Optional callbacks

    * `fetch_catalog/1` — dynamic model discovery
    * `fetch_usage/1` — quota / usage endpoint
    * `classify_http_error/3` — provider-specific error overrides
  """

  alias AgentEx.LLM.{Credentials, Model, Transport}

  @callback id() :: atom()
  @callback label() :: String.t()
  @callback transport() :: module()
  @callback default_base_url() :: String.t() | nil
  @callback env_vars() :: [String.t()]
  @callback default_models() :: [Model.t()]
  @callback request_headers(Credentials.t()) :: [{String.t(), String.t()}]
  @callback supports() :: MapSet.t(atom())

  @callback fetch_catalog(Credentials.t()) ::
              {:ok, [Model.t()]} | {:error, term()} | :not_supported

  @callback fetch_usage(Credentials.t()) ::
              {:ok, term()} | :not_supported

  @callback classify_http_error(non_neg_integer() | nil, term(), term()) ::
              {atom(), non_neg_integer() | nil} | :default

  @optional_callbacks fetch_catalog: 1,
                      fetch_usage: 1,
                      classify_http_error: 3

  @doc """
  Call a provider's `chat` via its declared transport.

  Builds the canonical params, resolves credentials, delegates to
  the transport for request building and response parsing, and
  performs the HTTP call.
  """
  @spec chat(provider :: module(), params :: map(), opts :: keyword()) ::
          {:ok, Transport.request()} | {:error, term()}
  def chat(provider, params, opts \\ []) do
    transport_mod = provider.transport()

    case Credentials.resolve(provider) do
      {:ok, creds} ->
        base_url = creds.base_url_override || provider.default_base_url()

        model =
          Keyword.get(opts, :model) ||
            get_default_model(provider)

        canonical = build_canonical(params, model)

        transport_opts =
          [
            base_url: base_url,
            api_key: creds.api_key,
            extra_headers: creds.headers
          ]

        request = transport_mod.build_chat_request(canonical, transport_opts)

        case Req.post(request.url,
               json: request.body,
               headers: request.headers,
               receive_timeout: 120_000
             ) do
          {:ok, %{status: status, body: resp_body, headers: resp_headers}} ->
            transport_mod.parse_chat_response(status, resp_body, resp_headers)

          {:error, exception} ->
            {:error,
             %AgentEx.LLM.Error{
               message: "HTTP error: #{Exception.message(exception)}",
               status: nil,
               classification: :timeout,
               raw: exception
             }}
        end

      :not_configured ->
        {:error,
         %AgentEx.LLM.Error{
           message:
             "#{provider.id()} not configured (set #{Enum.join(provider.env_vars(), " or ")})",
           status: nil,
           classification: :auth
         }}
    end
  end

  defp get_default_model(provider) do
    provider.default_models()
    |> Enum.find(&(&1.tier_hint == :primary))
    |> case do
      nil -> (provider.default_models() |> List.first() || %{id: "unknown"}).id
      model -> model.id
    end
  end

  defp build_canonical(params, model) do
    %{
      model: model,
      messages: get(params, "messages", :messages, []),
      system: get(params, "system", :system, nil),
      tools: get(params, "tools", :tools, []) || [],
      max_tokens: get(params, "max_tokens", :max_tokens, nil),
      temperature: get(params, "temperature", :temperature, nil),
      tool_choice: get(params, "tool_choice", :tool_choice, nil),
      cache_control: normalize_cache_control(get(params, "cache_control", :cache_control, nil))
    }
  end

  defp normalize_cache_control(nil), do: nil

  defp normalize_cache_control(%{} = m) do
    %{
      stable_hash: m["stable_hash"] || m[:stable_hash],
      prefix_changed: m["prefix_changed"] || m[:prefix_changed] || false
    }
  end

  defp normalize_cache_control(_), do: nil

  defp get(map, str_key, atom_key, default) do
    case Map.get(map, str_key) do
      nil -> Map.get(map, atom_key, default)
      val -> val
    end
  end
end
