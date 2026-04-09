defmodule AgentEx.LLM do
  @moduledoc """
  Top-level entry point for chat and embedding calls.

  Wraps `AgentEx.LLM.Provider` with two conveniences:

    * `chat/2` and `chat_tier/3` for chat completions
    * `embed/2` and `embed_tier/3` for vector embeddings

  Both flavours route through the configured provider stack and
  return canonical `%Response{}` / `{:ok, vectors, model_id}` shapes.

  ## Embed return shape

  `embed/2` and `embed_tier/3` always return a list of vectors,
  even when called with a single string input. The third tuple
  element is the model id used to produce the vectors so callers
  (e.g. mneme's reembed pipeline) can store provenance.

      {:ok, [vector, ...], "text-embedding-3-small"} | {:error, %Error{}}
  """

  alias AgentEx.LLM.{Catalog, Credentials, Error, Provider, ProviderRegistry}

  @type embed_result :: {:ok, [[float()]], String.t()} | {:error, Error.t()}

  @doc "Chat completion via a provider module + canonical params."
  def chat(params, opts \\ []) do
    provider =
      case Keyword.get(opts, :provider) do
        nil -> raise ArgumentError, "AgentEx.LLM.chat/2 requires :provider option"
        atom when is_atom(atom) -> ProviderRegistry.get(atom) || atom
      end

    Provider.chat(provider, params, opts)
  end

  @doc """
  Chat completion via tier resolution.

  Currently a thin wrapper that delegates to `chat/2` after picking
  the first chat-capable provider for the requested tier. The Phase
  5 retry walk in `AgentEx.Loop.Stages.LLMCall` does the more
  sophisticated route walking; this entry point is for callers that
  want a single dispatch.
  """
  def chat_tier(params, tier, opts \\ []) do
    case Catalog.find(tier: tier, has: :chat) do
      [%{provider: provider_id, id: model_id} | _] ->
        provider = ProviderRegistry.get(provider_id)

        chat(
          params,
          Keyword.merge(opts, provider: provider_id, model: model_id, _provider_module: provider)
        )

      [] ->
        {:error,
         %Error{message: "no provider available for tier #{tier}", classification: :permanent}}
    end
  end

  @doc """
  Generate embeddings for one or more strings via an explicit provider.

  Required opts:

    * `:provider` — provider id atom (e.g. `:openai`)
    * `:model`    — model id string (e.g. `"text-embedding-3-small"`)
  """
  @spec embed(String.t() | [String.t()], keyword()) :: embed_result()
  def embed(text_or_list, opts \\ []) do
    provider_id = Keyword.fetch!(opts, :provider)
    model_id = Keyword.fetch!(opts, :model)

    case lookup_provider(provider_id) do
      nil ->
        {:error,
         %Error{message: "unknown provider #{inspect(provider_id)}", classification: :permanent}}

      provider ->
        embed_via_provider(provider, model_id, text_or_list)
    end
  end

  @doc """
  Generate embeddings via tier-based model resolution.

  Tier resolution order:

    1. Explicit `opts[:model]` + `opts[:provider]` (skips Catalog)
    2. `Catalog.find(has: :embeddings, tier: tier)` → first match
    3. Fallback to first model with the `:embeddings` capability
  """
  @spec embed_tier(String.t() | [String.t()], atom(), keyword()) :: embed_result()
  def embed_tier(text_or_list, tier \\ :embeddings, opts \\ []) do
    case resolve_embedding_target(tier, opts) do
      {:ok, provider, model_id} ->
        embed_via_provider(provider, model_id, text_or_list)

      :none ->
        {:error,
         %Error{
           message: "no embedding model available for tier #{inspect(tier)}",
           classification: :permanent
         }}
    end
  end

  # ---- internals ----

  defp lookup_provider(provider_id) when is_atom(provider_id) do
    ProviderRegistry.get(provider_id)
  end

  defp lookup_provider(_), do: nil

  defp resolve_embedding_target(tier, opts) do
    explicit_model = Keyword.get(opts, :model)
    explicit_provider = Keyword.get(opts, :provider)

    cond do
      explicit_model && explicit_provider ->
        case lookup_provider(explicit_provider) do
          nil -> :none
          mod -> {:ok, mod, explicit_model}
        end

      true ->
        # Try tier-specific match first, then any embedding model.
        candidates =
          case Catalog.find(tier: tier, has: :embeddings) do
            [] -> Catalog.find(has: :embeddings)
            list -> list
          end

        candidates
        |> Enum.sort_by(&embedding_preference/1)
        |> Enum.find_value(:none, fn model ->
          case lookup_provider(model.provider) do
            nil -> false
            mod -> {:ok, mod, model.id}
          end
        end)
    end
  end

  # Sort key: lower is better. Prefer text-embedding-3-small as the
  # documented default, then any non-Ollama provider, then anything else.
  defp embedding_preference(model) do
    cond do
      model.id == "text-embedding-3-small" -> 0
      model.provider != :ollama -> 1
      true -> 2
    end
  end

  defp embed_via_provider(provider, model_id, text_or_list) do
    transport_mod = provider.transport()

    if function_exported?(transport_mod, :build_embedding_request, 2) do
      case Credentials.resolve(provider) do
        {:ok, creds} ->
          base_url = creds.base_url_override || provider.default_base_url()

          opts = [
            base_url: base_url,
            api_key: creds.api_key,
            model: model_id,
            extra_headers: creds.headers
          ]

          case transport_mod.build_embedding_request(text_or_list, opts) do
            :not_supported ->
              {:error,
               %Error{
                 message: "transport #{inspect(transport_mod)} does not support embeddings",
                 classification: :permanent
               }}

            request ->
              execute_embed(request, transport_mod, model_id)
          end

        :not_configured ->
          {:error,
           %Error{
             message:
               "#{provider.id()} not configured (set #{Enum.join(provider.env_vars(), " or ")})",
             classification: :auth
           }}
      end
    else
      {:error,
       %Error{
         message: "transport #{inspect(transport_mod)} does not implement embedding callbacks",
         classification: :permanent
       }}
    end
  end

  defp execute_embed(request, transport_mod, model_id) do
    start_time = System.monotonic_time()

    result =
      case Req.post(request.url,
             json: request.body,
             headers: request.headers,
             receive_timeout: 60_000
           ) do
        {:ok, %{status: status, body: body, headers: headers}} ->
          case transport_mod.parse_embedding_response(status, body, headers) do
            {:ok, vectors} -> {:ok, vectors, model_id}
            {:error, _} = err -> err
          end

        {:error, exception} ->
          {:error,
           %Error{
             message: "HTTP error: #{Exception.message(exception)}",
             classification: :timeout,
             raw: exception
           }}
      end

    duration = System.monotonic_time() - start_time
    emit_embed_telemetry(result, model_id, duration, request)
    result
  end

  defp emit_embed_telemetry(result, model_id, duration, request) do
    {input_count, status} =
      case result do
        {:ok, vectors, _} -> {length(vectors), :ok}
        {:error, _} -> {input_size(request), :error}
      end

    AgentEx.Telemetry.event(
      [:llm, :embed, :stop],
      %{
        duration: duration,
        input_count: input_count,
        cost_usd: 0.0
      },
      %{model: model_id, status: status}
    )
  end

  defp input_size(%{body: %{input: input}}) when is_list(input), do: length(input)
  defp input_size(%{body: %{input: input}}) when is_binary(input), do: 1
  defp input_size(_), do: 0
end
