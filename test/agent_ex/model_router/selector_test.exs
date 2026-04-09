defmodule AgentEx.ModelRouter.SelectorTest do
  use ExUnit.Case, async: true

  alias AgentEx.LLM.Model
  alias AgentEx.ModelRouter.Selector

  describe "rank/2" do
    test "returns models sorted by score" do
      analysis = %{
        complexity: :simple,
        required_capabilities: [:chat],
        needs_vision: false,
        needs_audio: false,
        needs_reasoning: false,
        needs_large_context: false,
        estimated_input_tokens: 100,
        explanation: ""
      }

      ranked = Selector.rank(analysis, :optimize_price)

      assert is_list(ranked)

      if length(ranked) >= 2 do
        scores = Enum.map(ranked, fn {_model, score} -> score end)
        assert scores == Enum.sort(scores)
      end
    end
  end

  describe "top/3" do
    test "returns at most N models" do
      analysis = %{
        complexity: :moderate,
        required_capabilities: [:chat],
        needs_vision: false,
        needs_audio: false,
        needs_reasoning: false,
        needs_large_context: false,
        estimated_input_tokens: 500,
        explanation: ""
      }

      top2 = Selector.top(analysis, :optimize_price, 2)

      assert length(top2) <= 2
    end
  end

  describe "select/3" do
    test "returns best model and analysis" do
      result =
        case Selector.select("Hello", :optimize_price) do
          {:ok, {model, returned_analysis}} ->
            assert %Model{} = model
            assert returned_analysis.complexity in [:simple, :moderate, :complex]
            :ok

          {:error, :no_models_available} ->
            :ok
        end

      assert result == :ok
    end
  end
end
