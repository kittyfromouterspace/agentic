defmodule AgentEx.LLM.Transport.AnthropicMessagesTest do
  use ExUnit.Case, async: true

  alias AgentEx.LLM.Response
  alias AgentEx.LLM.Transport.AnthropicMessages

  describe "id/0" do
    test "returns :anthropic_messages" do
      assert AnthropicMessages.id() == :anthropic_messages
    end
  end

  describe "build_chat_request/2 — cache_control" do
    test "no cache breakpoints when cache_control is absent" do
      params = %{
        model: "claude-opus-4-20250514",
        messages: [%{"role" => "user", "content" => "hi"}],
        system: "You are helpful.",
        tools: [%{"name" => "get_weather", "description" => "Get weather", "input_schema" => %{}}]
      }

      request = AnthropicMessages.build_chat_request(params, base_url: "https://api.anthropic.com/v1", api_key: "sk-test")

      # System stays as a plain string
      assert request.body[:system] == "You are helpful."

      # Tool has no cache_control
      [tool] = request.body[:tools]
      refute Map.has_key?(tool, "cache_control")
      refute Map.has_key?(tool, :cache_control)
    end

    test "no cache breakpoints when prefix_changed is true" do
      params = %{
        model: "claude-opus-4-20250514",
        messages: [%{"role" => "user", "content" => "hi"}],
        system: "You are helpful.",
        tools: [%{"name" => "get_weather", "description" => "Get weather", "input_schema" => %{}}],
        cache_control: %{stable_hash: "abc", prefix_changed: true}
      }

      request = AnthropicMessages.build_chat_request(params, base_url: "https://api.anthropic.com/v1", api_key: "sk-test")

      assert request.body[:system] == "You are helpful."
      [tool] = request.body[:tools]
      refute Map.has_key?(tool, "cache_control")
    end

    test "marks system prompt with cache_control when prefix_changed is false" do
      params = %{
        model: "claude-opus-4-20250514",
        messages: [%{"role" => "user", "content" => "hi"}],
        system: "You are helpful.",
        cache_control: %{stable_hash: "abc", prefix_changed: false}
      }

      request = AnthropicMessages.build_chat_request(params, base_url: "https://api.anthropic.com/v1", api_key: "sk-test")

      assert [
               %{
                 "type" => "text",
                 "text" => "You are helpful.",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ] = request.body[:system]
    end

    test "marks last tool with cache_control when prefix_changed is false" do
      params = %{
        model: "claude-opus-4-20250514",
        messages: [%{"role" => "user", "content" => "hi"}],
        tools: [
          %{"name" => "tool_a", "description" => "A", "input_schema" => %{}},
          %{"name" => "tool_b", "description" => "B", "input_schema" => %{}}
        ],
        cache_control: %{stable_hash: "abc", prefix_changed: false}
      }

      request = AnthropicMessages.build_chat_request(params, base_url: "https://api.anthropic.com/v1", api_key: "sk-test")

      [first, last] = request.body[:tools]
      refute Map.has_key?(first, "cache_control")
      assert last["cache_control"] == %{"type" => "ephemeral"}
    end

    test "tolerates string-keyed cache_control map" do
      params = %{
        model: "claude-opus-4-20250514",
        messages: [%{"role" => "user", "content" => "hi"}],
        system: "You are helpful.",
        cache_control: %{"stable_hash" => "abc", "prefix_changed" => false}
      }

      request = AnthropicMessages.build_chat_request(params, base_url: "https://api.anthropic.com/v1", api_key: "sk-test")

      assert [%{"cache_control" => %{"type" => "ephemeral"}}] = request.body[:system]
    end

    test "leaves nil system as nil even when caching enabled" do
      params = %{
        model: "claude-opus-4-20250514",
        messages: [%{"role" => "user", "content" => "hi"}],
        cache_control: %{stable_hash: "abc", prefix_changed: false}
      }

      request = AnthropicMessages.build_chat_request(params, base_url: "https://api.anthropic.com/v1", api_key: "sk-test")

      refute Map.has_key?(request.body, :system)
    end
  end

  describe "parse_chat_response/3 — cache tokens" do
    test "extracts cache_read_input_tokens and cache_creation_input_tokens" do
      body = %{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "stop_reason" => "end_turn",
        "model" => "claude-opus-4-20250514",
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 20,
          "cache_creation_input_tokens" => 1000,
          "cache_read_input_tokens" => 500
        }
      }

      assert {:ok, %Response{usage: usage}} = AnthropicMessages.parse_chat_response(200, body, %{})
      assert usage.input_tokens == 100
      assert usage.output_tokens == 20
      assert usage.cache_write == 1000
      assert usage.cache_read == 500
    end

    test "defaults cache fields to 0 when absent" do
      body = %{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "stop_reason" => "end_turn",
        "model" => "claude-opus-4-20250514",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
      }

      assert {:ok, %Response{usage: usage}} = AnthropicMessages.parse_chat_response(200, body, %{})
      assert usage.cache_read == 0
      assert usage.cache_write == 0
    end
  end
end
