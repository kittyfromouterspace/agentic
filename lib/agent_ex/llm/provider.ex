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

    case Credentials.resolve(provider, opts) do
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

  @doc """
  Streaming variant of `chat/3`.

  Calls the provider with `stream: true` and invokes `on_chunk.(text_delta)`
  for each text chunk received. Returns the complete `{:ok, Response.t()}`
  at the end, same as `chat/3`.

  The `on_chunk` callback in `opts` receives each text delta as a binary.
  """
  def stream_chat(provider, params, opts \\ []) do
    transport_mod = provider.transport()
    on_chunk = Keyword.get(opts, :on_chunk, fn _ -> :ok end)

    case Credentials.resolve(provider, opts) do
      {:ok, creds} ->
        base_url = creds.base_url_override || provider.default_base_url()

        model =
          Keyword.get(opts, :model) ||
            get_default_model(provider)

        canonical = build_canonical(params, model)

        transport_opts = [
          base_url: base_url,
          api_key: creds.api_key,
          extra_headers: creds.headers
        ]

        request = transport_mod.build_chat_request(canonical, transport_opts)
        body = Map.put(request.body, :stream, true)

        acc = %{text: "", tool_calls: [], model_id: nil, usage: nil, finish_reason: nil}

        stream_fun = fn {:data, data}, {req, resp} ->
          current_acc =
            if is_map(resp.body) and is_map_key(resp.body, :text), do: resp.body, else: acc

          updated_acc =
            data
            |> parse_sse_lines()
            |> Enum.reduce(current_acc, fn chunk_data, inner_acc ->
              process_stream_chunk(chunk_data, inner_acc, on_chunk)
            end)

          {:cont, {req, %{resp | body: updated_acc}}}
        end

        case Req.post(request.url,
               json: body,
               headers: request.headers,
               receive_timeout: 120_000,
               into: stream_fun
             ) do
          {:ok, %{status: 200, body: final_acc}} when is_map(final_acc) ->
            build_stream_response(final_acc)

          {:ok, %{status: 200, body: _}} ->
            # No chunks received — return empty response
            build_stream_response(acc)

          {:ok, %{status: status, body: resp_body, headers: resp_headers}} ->
            # Non-200: parse as error using the transport
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

  defp parse_sse_lines(data) when is_binary(data) do
    data
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn line ->
      line |> String.trim_leading("data:") |> String.trim()
    end)
    |> Enum.reject(&(&1 == "" or &1 == "[DONE]"))
    |> Enum.flat_map(fn json_str ->
      case Jason.decode(json_str) do
        {:ok, parsed} when is_map(parsed) -> [parsed]
        _ -> []
      end
    end)
  end

  defp process_stream_chunk(chunk, acc, on_chunk) do
    choice = List.first(chunk["choices"] || []) || %{}
    delta = choice["delta"] || %{}
    finish = choice["finish_reason"]

    # Accumulate text
    acc =
      case delta["content"] do
        text when is_binary(text) and text != "" ->
          on_chunk.(text)
          %{acc | text: acc.text <> text}

        _ ->
          acc
      end

    # Accumulate tool calls
    acc =
      case delta["tool_calls"] do
        [_ | _] = calls ->
          %{acc | tool_calls: merge_tool_call_deltas(acc.tool_calls, calls)}

        _ ->
          acc
      end

    # Capture model_id from first chunk
    acc =
      case chunk["model"] do
        model when is_binary(model) and acc.model_id == nil ->
          %{acc | model_id: model}

        _ ->
          acc
      end

    # Capture usage from final chunk (some providers include it)
    acc =
      case chunk["usage"] do
        %{} = usage when map_size(usage) > 0 ->
          %{acc | usage: usage}

        _ ->
          acc
      end

    # Capture finish reason
    if finish do
      %{acc | finish_reason: finish}
    else
      acc
    end
  end

  defp merge_tool_call_deltas(existing, new_deltas) do
    Enum.reduce(new_deltas, existing, fn delta, calls ->
      index = delta["index"] || 0

      case Enum.at(calls, index) do
        nil ->
          # New tool call
          calls ++ [delta]

        existing_call ->
          # Merge function arguments
          merged =
            Map.update(existing_call, "function", delta["function"] || %{}, fn existing_fn ->
              new_fn = delta["function"] || %{}

              Map.update(existing_fn, "arguments", new_fn["arguments"] || "", fn existing_args ->
                existing_args <> (new_fn["arguments"] || "")
              end)
            end)

          List.replace_at(calls, index, merged)
      end
    end)
  end

  defp build_stream_response(acc) do
    alias AgentEx.LLM.Response

    text_block =
      if acc.text != "" do
        [%{type: :text, text: acc.text}]
      else
        []
      end

    tool_blocks =
      acc.tool_calls
      |> Enum.map(fn tc ->
        func = tc["function"] || %{}
        args_str = func["arguments"] || "{}"

        input =
          case Jason.decode(args_str) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        %{
          type: :tool_use,
          id: tc["id"] || "call_#{System.unique_integer([:positive])}",
          name: func["name"] || "unknown",
          input: input
        }
      end)

    content = text_block ++ tool_blocks

    has_tools = tool_blocks != []
    stop_reason = translate_stream_finish(acc.finish_reason, has_tools)

    usage =
      case acc.usage do
        %{"prompt_tokens" => inp, "completion_tokens" => out} ->
          %{input_tokens: inp, output_tokens: out, cache_read: 0, cache_write: 0}

        _ ->
          %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}
      end

    {:ok,
     %Response{
       content: content,
       stop_reason: stop_reason,
       usage: usage,
       model_id: acc.model_id,
       raw: nil
     }}
  end

  defp translate_stream_finish(_reason, true), do: :tool_use
  defp translate_stream_finish("tool_calls", _), do: :tool_use
  defp translate_stream_finish("length", _), do: :max_tokens
  defp translate_stream_finish("stop", _), do: :end_turn
  defp translate_stream_finish("end_turn", _), do: :end_turn
  defp translate_stream_finish(nil, _), do: :end_turn
  defp translate_stream_finish(_, _), do: :end_turn

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
