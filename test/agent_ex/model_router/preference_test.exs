defmodule AgentEx.ModelRouter.PreferenceTest do
  use ExUnit.Case, async: true

  alias AgentEx.LLM.Model
  alias AgentEx.ModelRouter.Preference

  describe "parse/1" do
    test "accepts atoms" do
      assert {:ok, :optimize_price} = Preference.parse(:optimize_price)
      assert {:ok, :optimize_speed} = Preference.parse(:optimize_speed)
    end

    test "accepts shorthand strings" do
      assert {:ok, :optimize_price} = Preference.parse("price")
      assert {:ok, :optimize_speed} = Preference.parse("speed")
    end

    test "accepts full strings" do
      assert {:ok, :optimize_price} = Preference.parse("optimize_price")
      assert {:ok, :optimize_speed} = Preference.parse("optimize_speed")
    end

    test "rejects invalid values" do
      assert {:error, _} = Preference.parse(:unknown)
      assert {:error, _} = Preference.parse("fast")
    end
  end

  describe "score/3 with :optimize_price" do
    setup do
      lightweight = %Model{
        id: "cheap-model",
        provider: :test,
        tier_hint: :lightweight,
        cost: %{input: 0.15, output: 0.60},
        capabilities: MapSet.new([:chat, :tools]),
        context_window: 128_000
      }

      primary = %Model{
        id: "expensive-model",
        provider: :test,
        tier_hint: :primary,
        cost: %{input: 3.0, output: 15.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        context_window: 200_000
      }

      free = %Model{
        id: "free-model",
        provider: :test,
        tier_hint: :lightweight,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:chat, :tools, :free]),
        context_window: 32_000
      }

      {:ok, lightweight: lightweight, primary: primary, free: free}
    end

    test "prefers lightweight for simple tasks", ctx do
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

      lightweight_score = Preference.score(ctx.lightweight, :optimize_price, analysis)
      primary_score = Preference.score(ctx.primary, :optimize_price, analysis)

      assert lightweight_score < primary_score
    end

    test "prefers primary for complex tasks", ctx do
      analysis = %{
        complexity: :complex,
        required_capabilities: [:chat, :tools],
        needs_vision: false,
        needs_audio: false,
        needs_reasoning: true,
        needs_large_context: false,
        estimated_input_tokens: 5000,
        explanation: ""
      }

      lightweight_score = Preference.score(ctx.lightweight, :optimize_price, analysis)
      primary_score = Preference.score(ctx.primary, :optimize_price, analysis)

      assert primary_score < lightweight_score
    end

    test "heavily penalizes models missing vision capability", ctx do
      analysis = %{
        complexity: :moderate,
        required_capabilities: [:chat, :tools],
        needs_vision: true,
        needs_audio: false,
        needs_reasoning: false,
        needs_large_context: false,
        estimated_input_tokens: 500,
        explanation: ""
      }

      no_vision_score = Preference.score(ctx.lightweight, :optimize_price, analysis)
      has_vision_score = Preference.score(ctx.primary, :optimize_price, analysis)

      assert has_vision_score < no_vision_score
    end

    test "free model scores well for price optimization on simple tasks", ctx do
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

      free_score = Preference.score(ctx.free, :optimize_price, analysis)
      primary_score = Preference.score(ctx.primary, :optimize_price, analysis)

      assert free_score < primary_score
    end
  end

  describe "score/3 with :optimize_speed" do
    test "prefers lightweight/fast models for simple tasks" do
      lightweight = %Model{
        id: "fast-model",
        provider: :test,
        tier_hint: :lightweight,
        cost: %{input: 0.5, output: 1.0},
        capabilities: MapSet.new([:chat, :tools]),
        context_window: 128_000
      }

      primary = %Model{
        id: "slow-powerful-model",
        provider: :test,
        tier_hint: :primary,
        cost: %{input: 3.0, output: 15.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        context_window: 200_000
      }

      analysis = %{
        complexity: :simple,
        required_capabilities: [:chat],
        needs_vision: false,
        needs_audio: false,
        needs_reasoning: false,
        needs_large_context: false,
        estimated_input_tokens: 50,
        explanation: ""
      }

      fast_score = Preference.score(lightweight, :optimize_speed, analysis)
      slow_score = Preference.score(primary, :optimize_speed, analysis)

      assert fast_score < slow_score
    end

    test "prefers reasoning-capable models for complex tasks" do
      reasoning_model = %Model{
        id: "reasoning-model",
        provider: :test,
        tier_hint: :primary,
        cost: %{input: 5.0, output: 25.0},
        capabilities: MapSet.new([:chat, :tools, :reasoning]),
        context_window: 200_000
      }

      basic_model = %Model{
        id: "basic-model",
        provider: :test,
        tier_hint: :lightweight,
        cost: %{input: 0.5, output: 1.0},
        capabilities: MapSet.new([:chat, :tools]),
        context_window: 128_000
      }

      analysis = %{
        complexity: :complex,
        required_capabilities: [:chat, :tools],
        needs_vision: false,
        needs_audio: false,
        needs_reasoning: true,
        needs_large_context: false,
        estimated_input_tokens: 5000,
        explanation: ""
      }

      reasoning_score = Preference.score(reasoning_model, :optimize_speed, analysis)
      basic_score = Preference.score(basic_model, :optimize_speed, analysis)

      assert reasoning_score < basic_score
    end
  end

  describe "score/3 with large context requirements" do
    test "prefers models with large context windows" do
      large_ctx = %Model{
        id: "large-ctx-model",
        provider: :test,
        tier_hint: :primary,
        cost: %{input: 3.0, output: 15.0},
        capabilities: MapSet.new([:chat, :tools]),
        context_window: 200_000
      }

      small_ctx = %Model{
        id: "small-ctx-model",
        provider: :test,
        tier_hint: :lightweight,
        cost: %{input: 0.5, output: 1.0},
        capabilities: MapSet.new([:chat, :tools]),
        context_window: 8_000
      }

      analysis = %{
        complexity: :moderate,
        required_capabilities: [:chat],
        needs_vision: false,
        needs_audio: false,
        needs_reasoning: false,
        needs_large_context: true,
        estimated_input_tokens: 80_000,
        explanation: ""
      }

      large_score = Preference.score(large_ctx, :optimize_price, analysis)
      small_score = Preference.score(small_ctx, :optimize_price, analysis)

      assert large_score < small_score
    end
  end
end
