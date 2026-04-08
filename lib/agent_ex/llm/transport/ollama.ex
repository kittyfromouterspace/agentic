defmodule AgentEx.LLM.Transport.Ollama do
  @moduledoc """
  Transport for the Ollama wire format
  (`POST {base_url}/api/chat`, `POST {base_url}/api/embed`).

  Ollama runs locally so there's no auth and no rate limiting. The
  base URL defaults to `http://localhost:11434` but the provider may
  override it via `OLLAMA_HOST`.
  """

  @behaviour AgentEx.LLM.Transport

  alias AgentEx.LLM.{Error, ErrorClassifier, Response}

  @impl true
  def id, do: :ollama

  @impl true
  def build_chat_request(params, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    extra_headers = Keyword.get(opts, :extra_headers, [])

    url = String.trim_trailing(base_url, "/") <> "/api/chat"

    messages = transform_messages(Map.get(params, :messages, []), Map.get(params, :system))
    tools = transform_tools(Map.get(params, :tools, []))

    body =
      %{
        model: Map.fetch!(params, :model),
        messages: messages,
        stream: false
      }
      |> maybe_put(:tools, if(tools == [], do: nil, else: tools))
      |> maybe_put(:options, build_options(params))

    headers = [{"content-type", "application/json"}] ++ extra_headers

    %{method: :post, url: url, body: body, headers: headers}
  end

  @impl true
  def parse_chat_response(200, body, _headers) when is_map(body) do
    message = body["message"] || %{}
    done_reason = body["done_reason"] || "stop"

    text_block =
      case message["content"] do
        text when is_binary(text) and text != "" -> [%{type: :text, text: text}]
        _ -> []
      end

    tool_blocks =
      (message["tool_calls"] || [])
      |> Enum.map(&ollama_tool_call_to_block/1)
      |> Enum.reject(&is_nil/1)

    content = text_block ++ tool_blocks

    response = %Response{
      content: content,
      stop_reason: translate_done_reason(done_reason, tool_blocks != []),
      usage: %{
        input_tokens: body["prompt_eval_count"] || 0,
        output_tokens: body["eval_count"] || 0,
        cache_read: 0,
        cache_write: 0
      },
      model_id: body["model"],
      raw: body
    }

    {:ok, response}
  end

  def parse_chat_response(status, body, headers) do
    message = error_message(body)

    {classification, _retry} = ErrorClassifier.classify(status, message, headers)

    {:error,
     %Error{
       message: "Ollama error (#{status}): #{message}",
       status: status,
       classification: classification,
       raw: body
     }}
  end

  @impl true
  def parse_rate_limit(_headers), do: nil

  @impl true
  def build_embedding_request(text_or_list, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    model = Keyword.fetch!(opts, :model)
    extra_headers = Keyword.get(opts, :extra_headers, [])

    url = String.trim_trailing(base_url, "/") <> "/api/embed"

    body = %{
      model: model,
      input: text_or_list
    }

    headers = [{"content-type", "application/json"}] ++ extra_headers

    %{method: :post, url: url, body: body, headers: headers}
  end

  @impl true
  def parse_embedding_response(200, body, _headers) when is_map(body) do
    vectors = body["embeddings"] || []
    {:ok, vectors}
  end

  def parse_embedding_response(status, body, headers) do
    message = error_message(body)
    {classification, _retry} = ErrorClassifier.classify(status, message, headers)

    {:error,
     %Error{
       message: "Ollama embedding error (#{status}): #{message}",
       status: status,
       classification: classification,
       raw: body
     }}
  end

  # ----- request transforms -----

  defp transform_messages(messages, system) when is_list(messages) do
    base = Enum.map(messages, &transform_message/1)

    case system do
      nil -> base
      "" -> base
      sys when is_binary(sys) -> [%{"role" => "system", "content" => sys} | base]
      _ -> base
    end
  end

  defp transform_messages(_, _), do: []

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

  defp build_options(params) do
    case Map.get(params, :temperature) do
      nil -> nil
      t -> %{temperature: t}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----- response transforms -----

  defp ollama_tool_call_to_block(%{"function" => %{"name" => name} = func} = call) do
    %{
      type: :tool_use,
      id: call["id"] || generate_tool_id(name),
      name: name,
      input: func["arguments"] || %{}
    }
  end

  defp ollama_tool_call_to_block(_), do: nil

  defp generate_tool_id(name) do
    "ollama-#{name}-#{System.unique_integer([:positive])}"
  end

  defp translate_done_reason(_reason, true), do: :tool_use
  defp translate_done_reason("tool_calls", _), do: :tool_use
  defp translate_done_reason("length", _), do: :max_tokens
  defp translate_done_reason("stop", _), do: :end_turn
  defp translate_done_reason(_, _), do: :end_turn

  defp error_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp error_message(body) when is_binary(body), do: body
  defp error_message(other), do: inspect(other, limit: 200)
end
