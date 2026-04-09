defmodule AgentEx.LLM.Transport.OllamaTest do
  use ExUnit.Case, async: true

  alias AgentEx.LLM.Transport.Ollama
  alias AgentEx.LLM.{Error, Response}

  describe "id/0" do
    test "returns :ollama" do
      assert Ollama.id() == :ollama
    end
  end

  describe "build_chat_request/2" do
    test "builds a POST request with messages" do
      params = %{
        model: "llama3.2",
        messages: [%{"role" => "user", "content" => "hello"}]
      }

      request = Ollama.build_chat_request(params, base_url: "http://localhost:11434")

      assert request.method == :post
      assert request.url == "http://localhost:11434/api/chat"
      assert request.body.model == "llama3.2"
      assert request.body.stream == false
      assert [%{"role" => "user", "content" => "hello"}] = request.body.messages
    end

    test "prepends system message when provided" do
      params = %{
        model: "llama3.2",
        system: "You are helpful.",
        messages: [%{"role" => "user", "content" => "hi"}]
      }

      request = Ollama.build_chat_request(params, base_url: "http://localhost:11434")

      assert [
               %{"role" => "system", "content" => "You are helpful."},
               %{"role" => "user", "content" => "hi"}
             ] = request.body.messages
    end

    test "passes tools through" do
      params = %{
        model: "llama3.2",
        messages: [],
        tools: [
          %{
            "name" => "get_weather",
            "description" => "Get weather",
            "input_schema" => %{"type" => "object"}
          }
        ]
      }

      request = Ollama.build_chat_request(params, base_url: "http://localhost:11434")

      assert [%{"type" => "function", "function" => %{"name" => "get_weather"}}] =
               request.body[:tools]
    end
  end

  describe "parse_chat_response/3" do
    test "translates a successful response" do
      body = %{
        "model" => "llama3.2",
        "message" => %{"role" => "assistant", "content" => "hi there"},
        "done_reason" => "stop",
        "prompt_eval_count" => 12,
        "eval_count" => 4
      }

      assert {:ok, %Response{} = resp} = Ollama.parse_chat_response(200, body, %{})
      assert resp.stop_reason == :end_turn
      assert resp.usage.input_tokens == 12
      assert resp.usage.output_tokens == 4
      assert [%{type: :text, text: "hi there"}] = resp.content
    end

    test "translates a tool call response" do
      body = %{
        "model" => "llama3.2",
        "message" => %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "function" => %{"name" => "get_weather", "arguments" => %{"location" => "sf"}}
            }
          ]
        },
        "done_reason" => "stop"
      }

      assert {:ok, %Response{} = resp} = Ollama.parse_chat_response(200, body, %{})
      assert resp.stop_reason == :tool_use

      assert [%{type: :tool_use, name: "get_weather", input: %{"location" => "sf"}}] =
               resp.content
    end

    test "wraps non-200 in an Error with classification" do
      body = %{"error" => "model not found"}

      assert {:error, %Error{status: 404, classification: :model_not_found}} =
               Ollama.parse_chat_response(404, body, %{})
    end
  end

  describe "build_embedding_request/2" do
    test "builds an embedding POST" do
      request =
        Ollama.build_embedding_request("hello world",
          base_url: "http://localhost:11434",
          model: "nomic-embed-text"
        )

      assert request.method == :post
      assert request.url == "http://localhost:11434/api/embed"
      assert request.body.model == "nomic-embed-text"
      assert request.body.input == "hello world"
    end

    test "supports list input" do
      request =
        Ollama.build_embedding_request(["a", "b"],
          base_url: "http://localhost:11434",
          model: "nomic-embed-text"
        )

      assert request.body.input == ["a", "b"]
    end
  end

  describe "parse_embedding_response/3" do
    test "extracts vectors from a 200 response" do
      body = %{"embeddings" => [[0.1, 0.2], [0.3, 0.4]]}

      assert {:ok, [[0.1, 0.2], [0.3, 0.4]]} =
               Ollama.parse_embedding_response(200, body, %{})
    end

    test "wraps non-200 in an Error" do
      assert {:error, %Error{status: 500, classification: :transient}} =
               Ollama.parse_embedding_response(500, %{"error" => "boom"}, %{})
    end
  end

  describe "parse_rate_limit/1" do
    test "always returns nil" do
      assert Ollama.parse_rate_limit(%{}) == nil
      assert Ollama.parse_rate_limit([]) == nil
    end
  end
end
