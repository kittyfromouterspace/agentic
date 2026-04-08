defmodule AgentEx.LLM.Transport.OpenAIChatCompletions do
  @moduledoc """
  Transport for the OpenAI Chat Completions wire format
  (`POST {base_url}/chat/completions`).

  This is the lingua franca of the OpenAI-compatible provider zoo:
  OpenAI itself, OpenRouter, Groq, Together, Fireworks, Cerebras,
  Mistral, DeepSeek, LM Studio, vLLM, … all speak it. The transport
  knows nothing about any of those providers individually — the base
  URL and any provider-specific headers are supplied via `opts`.

  ## What lives here vs. in a shim

  The transport owns:

    * canonical params -> wire request body translation
      (messages, tools, tool_choice)
    * wire response -> `AgentEx.LLM.Response` translation
      (choices/message/content -> content blocks,
       tool_calls -> `:tool_use` blocks,
       finish_reason -> `:end_turn | :tool_use | :max_tokens`)
    * rate-limit header parsing
    * HTTP error parsing into `AgentEx.LLM.Error` with phase-1
      classification

  The shim owns the api key, base URL, and any provider-specific
  headers (`HTTP-Referer`, `X-Title`, …). It also performs the
  actual `Req.post` call.
  """

  @behaviour AgentEx.LLM.Transport

  alias AgentEx.LLM.{Error, ErrorClassifier, RateLimit, Response}

  @impl true
  def id, do: :openai_chat_completions

  @impl true
  def build_chat_request(params, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    api_key = Keyword.fetch!(opts, :api_key)
    extra_headers = Keyword.get(opts, :extra_headers, [])

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    messages = transform_messages(Map.get(params, :messages, []))
    tools = transform_tools(Map.get(params, :tools, []))
    tool_choice = transform_tool_choice(Map.get(params, :tool_choice))

    body =
      %{
        model: Map.fetch!(params, :model),
        messages: messages,
        max_tokens: Map.get(params, :max_tokens) || 4096
      }
      |> maybe_put(:temperature, Map.get(params, :temperature))
      |> maybe_put(:tools, if(tools == [], do: nil, else: tools))
      |> maybe_put(:tool_choice, tool_choice)

    headers =
      [
        {"Authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ] ++ extra_headers

    %{method: :post, url: url, body: body, headers: headers}
  end

  @impl true
  def parse_chat_response(200, body, headers) when is_map(body) do
    choice = hd(body["choices"] || [%{}])
    message = choice["message"] || %{}
    finish_reason = choice["finish_reason"] || "stop"

    text_block =
      case message["content"] do
        text when is_binary(text) and text != "" -> [%{type: :text, text: text}]
        _ -> []
      end

    tool_blocks =
      (message["tool_calls"] || [])
      |> Enum.map(&openai_tool_call_to_block/1)
      |> Enum.reject(&is_nil/1)

    content = text_block ++ tool_blocks

    response = %Response{
      content: content,
      stop_reason: translate_finish_reason(finish_reason, tool_blocks != []),
      usage: %{
        input_tokens: get_in(body, ["usage", "prompt_tokens"]) || 0,
        output_tokens: get_in(body, ["usage", "completion_tokens"]) || 0,
        cache_read: 0,
        cache_write: 0
      },
      model_id: body["model"],
      raw: body
    }

    _ = headers
    {:ok, response}
  end

  def parse_chat_response(status, body, headers) do
    rate = parse_rate_limit(headers)
    retry_after_ms = parse_retry_after(headers, status)

    message = error_message(body)

    {classification, _retry} = ErrorClassifier.classify(status, message, headers)

    {:error,
     %Error{
       message: "OpenAI Chat Completions error (#{status}): #{message}",
       status: status,
       retry_after_ms: retry_after_ms,
       rate_limit: rate,
       classification: classification,
       raw: body
     }}
  end

  @impl true
  def build_embedding_request(text_or_list, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.fetch!(opts, :model)
    extra_headers = Keyword.get(opts, :extra_headers, [])

    url = String.trim_trailing(base_url, "/") <> "/embeddings"

    body = %{
      model: model,
      input: text_or_list,
      encoding_format: "float"
    }

    headers =
      [
        {"Authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ] ++ extra_headers

    %{method: :post, url: url, body: body, headers: headers}
  end

  @impl true
  def parse_embedding_response(200, body, _headers) when is_map(body) do
    vectors =
      (body["data"] || [])
      |> Enum.sort_by(fn d -> d["index"] || 0 end)
      |> Enum.map(fn d -> d["embedding"] || [] end)

    {:ok, vectors}
  end

  def parse_embedding_response(status, body, headers) do
    rate = parse_rate_limit(headers)
    retry_after_ms = parse_retry_after(headers, status)
    message = error_message(body)

    {classification, _retry} = ErrorClassifier.classify(status, message, headers)

    {:error,
     %Error{
       message: "OpenAI embeddings error (#{status}): #{message}",
       status: status,
       retry_after_ms: retry_after_ms,
       rate_limit: rate,
       classification: classification,
       raw: body
     }}
  end

  @impl true
  def parse_rate_limit(headers) do
    %RateLimit{
      limit: parse_int_header(headers, "x-ratelimit-limit"),
      remaining: parse_int_header(headers, "x-ratelimit-remaining"),
      reset_at_ms: parse_int_header(headers, "x-ratelimit-reset")
    }
  end

  # ----- request transforms -----

  defp transform_messages(messages) when is_list(messages) do
    Enum.map(messages, &transform_message/1)
  end

  defp transform_messages(_), do: []

  defp transform_message(%{"role" => role, "content" => content}) when is_binary(content) do
    %{"role" => role, "content" => content}
  end

  defp transform_message(%{"role" => role, "content" => content}) when is_list(content) do
    %{"role" => role, "content" => flatten_content_blocks(content)}
  end

  defp transform_message(%{role: role, content: content}) do
    transform_message(%{"role" => role, "content" => content})
  end

  defp transform_message(other), do: other

  defp flatten_content_blocks(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "tool_result", "content" => c} when is_binary(c) -> c
      %{"type" => "tool_use"} = tu -> "[tool_use #{tu["name"]}]"
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp transform_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool["name"] || tool[:name],
          "description" => tool["description"] || tool[:description] || "",
          "parameters" => tool["input_schema"] || tool[:input_schema] || %{"type" => "object"}
        }
      }
    end)
  end

  defp transform_tools(_), do: []

  defp transform_tool_choice(nil), do: nil
  defp transform_tool_choice(:auto), do: "auto"
  defp transform_tool_choice(:none), do: "none"
  defp transform_tool_choice(:any), do: "required"
  defp transform_tool_choice(:required), do: "required"
  defp transform_tool_choice(%{name: name}), do: %{"type" => "function", "function" => %{"name" => name}}
  defp transform_tool_choice(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----- response transforms -----

  defp openai_tool_call_to_block(%{"id" => id, "function" => %{"name" => name} = func}) do
    %{
      type: :tool_use,
      id: id,
      name: name,
      input: decode_arguments(func["arguments"])
    }
  end

  defp openai_tool_call_to_block(_), do: nil

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_arguments(args) when is_map(args), do: args
  defp decode_arguments(_), do: %{}

  defp translate_finish_reason(_reason, true), do: :tool_use
  defp translate_finish_reason("tool_calls", _), do: :tool_use
  defp translate_finish_reason("function_call", _), do: :tool_use
  defp translate_finish_reason("length", _), do: :max_tokens
  defp translate_finish_reason("stop", _), do: :end_turn
  defp translate_finish_reason("end_turn", _), do: :end_turn
  defp translate_finish_reason("content_filter", _), do: :end_turn
  defp translate_finish_reason(_, _), do: :end_turn

  # ----- header parsing -----

  defp header_value(headers, key) when is_map(headers) do
    case Map.get(headers, key) do
      [val | _] -> val
      val when is_binary(val) -> val
      _ -> nil
    end
  end

  defp header_value(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) -> if String.downcase(k) == key, do: v
      _ -> nil
    end)
  end

  defp header_value(_, _), do: nil

  defp parse_int_header(headers, key) do
    case header_value(headers, key) do
      nil ->
        nil

      val ->
        case Integer.parse(to_string(val)) do
          {n, _} -> n
          _ -> nil
        end
    end
  end

  # Retry-After is only meaningful on 429 (and some 503s). Per RFC 7231
  # it is either an integer number of seconds or an HTTP date — handle
  # the integer case here.
  defp parse_retry_after(headers, status) when status in [429, 503] do
    case header_value(headers, "retry-after") do
      nil ->
        case parse_int_header(headers, "x-ratelimit-reset") do
          nil ->
            nil

          reset_ms ->
            now_ms = System.system_time(:millisecond)
            max(reset_ms - now_ms, 0)
        end

      val ->
        case Integer.parse(to_string(val)) do
          {seconds, _} -> seconds * 1000
          _ -> nil
        end
    end
  end

  defp parse_retry_after(_, _), do: nil

  # ----- error message -----

  defp error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp error_message(body) when is_binary(body), do: body
  defp error_message(other), do: inspect(other, limit: 200)
end
