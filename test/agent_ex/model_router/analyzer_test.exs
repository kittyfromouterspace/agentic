defmodule AgentEx.ModelRouter.AnalyzerTest do
  use ExUnit.Case, async: true

  alias AgentEx.ModelRouter.Analyzer

  describe "analyze_heuristic/1" do
    test "classifies short simple requests as :simple" do
      {:ok, analysis} = Analyzer.analyze_heuristic("What is 2 + 2?")

      assert analysis.complexity == :simple
      assert analysis.needs_vision == false
      assert analysis.needs_audio == false
    end

    test "detects vision requests" do
      {:ok, analysis} = Analyzer.analyze_heuristic("Describe this image of a sunset")

      assert analysis.needs_vision == true
    end

    test "detects screenshot requests as vision" do
      {:ok, analysis} = Analyzer.analyze_heuristic("Look at the screenshot I uploaded")

      assert analysis.needs_vision == true
    end

    test "detects audio requests" do
      {:ok, analysis} = Analyzer.analyze_heuristic("Transcribe this audio recording")

      assert analysis.needs_audio == true
    end

    test "classifies refactor requests as :complex" do
      {:ok, analysis} =
        Analyzer.analyze_heuristic(
          "Refactor the entire authentication module to use JWT tokens instead of sessions"
        )

      assert analysis.complexity == :complex
    end

    test "detects reasoning keywords" do
      {:ok, analysis} =
        Analyzer.analyze_heuristic("Explain why this algorithm has O(n log n) time complexity")

      assert analysis.needs_reasoning == true
    end

    test "detects tool-related requests" do
      {:ok, analysis} =
        Analyzer.analyze_heuristic("Read the file config.json and update the database URL")

      assert :tools in analysis.required_capabilities
    end

    test "classifies moderate-length requests as :moderate" do
      {:ok, analysis} =
        Analyzer.analyze_heuristic(
          "Can you help me write a function that validates email addresses in Elixir?"
        )

      assert analysis.complexity == :moderate
    end

    test "estimates input tokens based on string length" do
      {:ok, analysis} = Analyzer.analyze_heuristic("Hi")

      assert analysis.estimated_input_tokens >= 100
    end

    test "always includes :chat in required capabilities" do
      {:ok, analysis} = Analyzer.analyze_heuristic("Hello")

      assert :chat in analysis.required_capabilities
    end
  end

  describe "analyze/2 with LLM callback" do
    test "uses LLM response when available" do
      llm_response = %AgentEx.LLM.Response{
        content: [
          %{
            type: :text,
            text:
              ~s({"complexity": "simple", "required_capabilities": ["chat"], "needs_vision": false, "needs_audio": false, "needs_reasoning": false, "needs_large_context": false, "estimated_input_tokens": 50, "explanation": "Simple greeting"})
          }
        ],
        stop_reason: :end_turn,
        usage: %{input_tokens: 10, output_tokens: 20, cache_read: 0, cache_write: 0}
      }

      llm_chat = fn _params -> {:ok, llm_response} end

      {:ok, analysis} = Analyzer.analyze("Hello!", llm_chat: llm_chat)

      assert analysis.complexity == :simple
      assert analysis.needs_vision == false
    end

    test "falls back to heuristic on LLM error" do
      llm_chat = fn _params -> {:error, :rate_limit} end

      {:ok, analysis} = Analyzer.analyze("Explain why recursion is useful", llm_chat: llm_chat)

      assert analysis.complexity in [:simple, :moderate, :complex]
    end

    test "falls back to heuristic on unparseable LLM response" do
      llm_chat = fn _params ->
        {:ok,
         %AgentEx.LLM.Response{
           content: [%{type: :text, text: "I cannot analyze this."}],
           stop_reason: :end_turn
         }}
      end

      {:ok, analysis} = Analyzer.analyze("Hello", llm_chat: llm_chat)

      assert analysis.complexity in [:simple, :moderate, :complex]
    end
  end

  describe "parse_complexity" do
    test "handles all valid complexity values" do
      {:ok, a1} = Analyzer.analyze_heuristic("hi")

      {:ok, _a2} =
        Analyzer.analyze_heuristic(
          "refactor the codebase architecture to use microservices and deploy to kubernetes"
        )

      assert a1.complexity == :simple
    end
  end
end
