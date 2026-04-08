defmodule AgentEx.LLM.Transport.AnthropicMessages do
  @moduledoc """
  Transport for the Anthropic Messages API
  (`POST {base_url}/messages`).

  As with `AgentEx.LLM.Transport.OpenAIChatCompletions`, this module is
  pure: no network I/O, no credential lookup, no Worth-prefixed code.
  The shim supplies the api key, base URL, and the
  `anthropic-version` header via `opts[:extra_headers]`.
  """

  @behaviour AgentEx.LLM.Transport

  alias AgentEx.LLM.{Error, ErrorClassifier, RateLimit, Response}

  def default_base_url, do: "https://api.anthropic.com/v1"

  @impl true
  def id, do: :anthropic_messages

  @impl true
  def build_chat_request(params, opts) do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    api_key = Keyword.fetch!(opts, :api_key)
    extra_headers = Keyword.get(opts, :extra_headers, [])

    url = String.trim_trailing(base_url, "/") <> "/messages"

    cache_enabled = cache_breakpoint_enabled?(Map.get(params, :cache_control))

    messages = transform_messages(Map.get(params, :messages, []))
    tools =
      params
      |> Map.get(:tools, [])
      |> transform_tools()
      |> apply_tool_cache_control(cache_enabled)

    system =
      params
      |> Map.get(:system)
      |> apply_system_cache_control(cache_enabled)

    body =
      %{
        model: Map.fetch!(params, :model),
        max_tokens: Map.get(params, :max_tokens) || 4096,
        messages: messages
      }
      |> maybe_put(:system, system)
      |> maybe_put(:temperature, Map.get(params, :temperature))
      |> maybe_put(:tools, if(tools == [], do: nil, else: tools))
      |> maybe_put(:tool_choice, Map.get(params, :tool_choice))

    headers =
      [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ] ++ extra_headers

    %{method: :post, url: url, body: body, headers: headers}
  end

  # Cache is enabled when the caller flagged the prefix as unchanged
  # from last call. The first call after prefix changes won't have a
  # cache breakpoint set; the second and subsequent calls will, which
  # is exactly when Anthropic's prompt cache pays off.
  defp cache_breakpoint_enabled?(%{prefix_changed: false}), do: true
  defp cache_breakpoint_enabled?(%{"prefix_changed" => false}), do: true
  defp cache_breakpoint_enabled?(_), do: false

  # System prompt: wrap a string into the structured form Anthropic
  # accepts (`[%{type: "text", text: ..., cache_control: ...}]`) so
  # we can mark a cache breakpoint on it.
  defp apply_system_cache_control(nil, _enabled), do: nil
  defp apply_system_cache_control("", _enabled), do: nil

  defp apply_system_cache_control(text, true) when is_binary(text) do
    [%{"type" => "text", "text" => text, "cache_control" => %{"type" => "ephemeral"}}]
  end

  defp apply_system_cache_control(text, false) when is_binary(text), do: text

  defp apply_system_cache_control(blocks, true) when is_list(blocks) do
    case blocks do
      [] ->
        []

      list ->
        last = List.last(list)
        new_last = Map.put(last, "cache_control", %{"type" => "ephemeral"})
        List.replace_at(list, length(list) - 1, new_last)
    end
  end

  defp apply_system_cache_control(blocks, false) when is_list(blocks), do: blocks
  defp apply_system_cache_control(other, _), do: other

  # Tools: cache_control on the LAST tool definition tells Anthropic
  # to cache everything up through the tools section. The tools list
  # changes far less often than messages, so this is high-leverage.
  defp apply_tool_cache_control([], _enabled), do: []

  defp apply_tool_cache_control(tools, true) when is_list(tools) do
    last = List.last(tools)

    # Mark the cache breakpoint on the last tool, using whichever key
    # convention the tool already uses. JSON-encoding both produces
    # `"cache_control"` on the wire.
    new_last =
      if is_map(last) do
        if Map.has_key?(last, :name) do
          Map.put(last, :cache_control, %{type: "ephemeral"})
        else
          Map.put(last, "cache_control", %{"type" => "ephemeral"})
        end
      else
        last
      end

    List.replace_at(tools, length(tools) - 1, new_last)
  end

  defp apply_tool_cache_control(tools, false), do: tools

  @impl true
  def parse_chat_response(200, body, _headers) when is_map(body) do
    content_blocks =
      (body["content"] || [])
      |> Enum.map(&block_from_anthropic/1)
      |> Enum.reject(&is_nil/1)

    response = %Response{
      content: content_blocks,
      stop_reason: translate_stop_reason(body["stop_reason"]),
      usage: %{
        input_tokens: get_in(body, ["usage", "input_tokens"]) || 0,
        output_tokens: get_in(body, ["usage", "output_tokens"]) || 0,
        cache_read: get_in(body, ["usage", "cache_read_input_tokens"]) || 0,
        cache_write: get_in(body, ["usage", "cache_creation_input_tokens"]) || 0
      },
      model_id: body["model"],
      raw: body
    }

    {:ok, response}
  end

  def parse_chat_response(status, body, headers) do
    rate = parse_rate_limit(headers)
    retry_after_ms = parse_retry_after(headers, status)

    message = error_message(body)

    {classification, _retry} = ErrorClassifier.classify(status, message, headers)

    {:error,
     %Error{
       message: "Anthropic Messages error (#{status}): #{message}",
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
      limit: parse_int_header(headers, "anthropic-ratelimit-requests-limit"),
      remaining: parse_int_header(headers, "anthropic-ratelimit-requests-remaining"),
      reset_at_ms: nil
    }
  end

  # ----- request transforms -----

  defp transform_messages(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => msg["role"] || msg[:role],
        "content" => msg["content"] || msg[:content]
      }
    end)
  end

  defp transform_messages(_), do: []

  defp transform_tools(nil), do: []
  defp transform_tools(tools) when is_list(tools), do: tools

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----- response transforms -----

  defp block_from_anthropic(%{"type" => "text", "text" => text}) do
    %{type: :text, text: text}
  end

  defp block_from_anthropic(%{"type" => "tool_use", "id" => id, "name" => name} = b) do
    %{type: :tool_use, id: id, name: name, input: b["input"] || %{}}
  end

  defp block_from_anthropic(_), do: nil

  defp translate_stop_reason("end_turn"), do: :end_turn
  defp translate_stop_reason("tool_use"), do: :tool_use
  defp translate_stop_reason("max_tokens"), do: :max_tokens
  defp translate_stop_reason("stop_sequence"), do: :end_turn
  defp translate_stop_reason(nil), do: :end_turn
  defp translate_stop_reason(_), do: :end_turn

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

  defp parse_retry_after(headers, status) when status in [429, 503] do
    case header_value(headers, "retry-after") do
      nil ->
        nil

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
