defmodule Agentic.ModelRouter.PreferenceTest do
  use ExUnit.Case, async: true

  alias Agentic.LLM.Model
  alias Agentic.ModelRouter.Preference

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

  # ── Multi-pathway score_pathway/3 (Phase 1.6) ────────────────

  describe "score_pathway/3 — cost_profile dominates within a canonical group" do
    alias Agentic.LLM.ProviderAccount

    defp model_with_cost(input, output) do
      %Model{
        id: "test-model",
        provider: :anthropic,
        capabilities: MapSet.new([:chat, :tools]),
        cost: %{input: input, output: output},
        tier_hint: :primary,
        source: :static
      }
    end

    test "subscription_included beats pay_per_token under :optimize_price" do
      model = model_with_cost(3.0, 15.0)

      sub = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :subscription_included,
        availability: :ready
      }

      ppt = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :pay_per_token,
        availability: :ready
      }

      assert Preference.score_pathway(model, sub, :optimize_price) <
               Preference.score_pathway(model, ppt, :optimize_price)
    end

    test "free beats subscription_included under :optimize_price" do
      model = model_with_cost(0.0, 0.0)

      free = %ProviderAccount{
        provider: :ollama,
        cost_profile: :free,
        availability: :ready
      }

      sub = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :subscription_included,
        availability: :ready
      }

      assert Preference.score_pathway(model, free, :optimize_price) <
               Preference.score_pathway(model, sub, :optimize_price)
    end

    test "degraded availability adds a small penalty over ready" do
      model = model_with_cost(3.0, 15.0)

      ready = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :pay_per_token,
        availability: :ready
      }

      degraded = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :pay_per_token,
        availability: :degraded
      }

      assert Preference.score_pathway(model, degraded, :optimize_price) >
               Preference.score_pathway(model, ready, :optimize_price)
    end

    test "rate_limited gets a heavier penalty than degraded" do
      model = model_with_cost(3.0, 15.0)
      until = DateTime.add(DateTime.utc_now(), 60, :second)

      degraded = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :pay_per_token,
        availability: :degraded
      }

      rate_limited = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :pay_per_token,
        availability: {:rate_limited, until}
      }

      assert Preference.score_pathway(model, rate_limited, :optimize_price) >
               Preference.score_pathway(model, degraded, :optimize_price)
    end

    test "saturated subscription quota tapers above fresh pay_per_token" do
      model = model_with_cost(3.0, 15.0)

      # 2x the cap — should fully cliff (3 + 50*1.0 = +53) and
      # outweigh the subscription's -5 cost-profile bonus, flipping
      # the ranking so the router falls back to pay-per-token.
      sub_saturated = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :subscription_included,
        availability: :ready,
        quotas: %{tokens_used: 200_000, tokens_limit: 100_000, period_end: DateTime.utc_now()}
      }

      ppt = %ProviderAccount{
        provider: :openrouter,
        cost_profile: :pay_per_token,
        availability: :ready
      }

      assert Preference.score_pathway(model, sub_saturated, :optimize_price) >
               Preference.score_pathway(model, ppt, :optimize_price)
    end

    test "subscription quota pressure increases score monotonically" do
      model = model_with_cost(3.0, 15.0)

      light = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :subscription_included,
        availability: :ready,
        quotas: %{tokens_used: 10_000, tokens_limit: 100_000, period_end: DateTime.utc_now()}
      }

      heavy = %ProviderAccount{
        provider: :anthropic,
        cost_profile: :subscription_included,
        availability: :ready,
        quotas: %{tokens_used: 95_000, tokens_limit: 100_000, period_end: DateTime.utc_now()}
      }

      assert Preference.score_pathway(model, light, :optimize_price) <
               Preference.score_pathway(model, heavy, :optimize_price)
    end
  end
end
