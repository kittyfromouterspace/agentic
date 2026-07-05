defmodule Agentic.LLM.CanonicalTest do
  @moduledoc """
  Smoke tests for `Agentic.LLM.Canonical` — the (provider, model_id) →
  canonical_id resolver. We don't hit the live `models.dev` endpoint
  in tests; the static-override table and pattern rules are the
  surfaces under test here.
  """

  use ExUnit.Case, async: false

  alias Agentic.LLM.Canonical

  describe "for_model/2 — static overrides" do
    test "Anthropic dated id collapses to family canonical" do
      assert Canonical.for_model(:anthropic, "claude-sonnet-4-20250514") ==
               "claude-sonnet-4"
    end

    test "Claude Code short alias maps to the same canonical" do
      assert Canonical.for_model(:claude_code, "sonnet") == "claude-sonnet-4"
    end

    test "Codex bare model id maps to itself" do
      assert Canonical.for_model(:codex, "gpt-5.5") == "gpt-5.5"
    end

    test "z.ai GLM family is seeded" do
      assert Canonical.for_model(:zai, "glm-4.7") == "glm-4.7"
    end

    test "z.ai GLM-5 family (coding plan) is seeded" do
      assert Canonical.for_model(:zai, "glm-5.2") == "glm-5.2"
      assert Canonical.for_model(:zai, "glm-5v-turbo") == "glm-5v-turbo"
    end

    test "Moonshot direct K2 family is seeded" do
      assert Canonical.for_model(:moonshot, "kimi-k2.7-code") == "kimi-k2.7-code"
      assert Canonical.for_model(:moonshot, "kimi-k2.6") == "kimi-k2.6"
    end

    test "Moonshot highspeed variant collapses onto the code canonical" do
      assert Canonical.for_model(:moonshot, "kimi-k2.7-code-highspeed") ==
               "kimi-k2.7-code"
    end

    test "Kimi For Coding aliases collapse onto the K2.7 code canonical" do
      assert Canonical.for_model(:kimi_coding, "kimi-for-coding") == "kimi-k2.7-code"
      assert Canonical.for_model(:kimi_coding, "k2p7") == "kimi-k2.7-code"
    end

    test "Gemini CLI family is seeded" do
      assert Canonical.for_model(:gemini, "google/gemini-3-pro") == "gemini-3-pro"
    end
  end

  describe "for_model/2 — pattern rules" do
    test "OpenRouter strips org prefix for unknown models" do
      assert Canonical.for_model(:openrouter, "some-org/some-model") == "some-model"
    end

    test "OpenCode strips org prefix for unknown models" do
      assert Canonical.for_model(:opencode, "z-ai/glm-future") == "glm-future"
    end
  end

  describe "for_model/2 — fallback" do
    test "unknown (provider, id) falls back to provider:id format" do
      assert Canonical.for_model(:never_heard_of, "weird-model") ==
               "never_heard_of:weird-model"
    end

    test "non-binary id returns nil" do
      assert Canonical.for_model(:anthropic, nil) == nil
    end
  end

  describe "info/0" do
    test "returns a map with model_count and last_fetch fields" do
      info = Canonical.info()
      assert is_map(info)
      assert Map.has_key?(info, :model_count)
      assert Map.has_key?(info, :last_fetch)
    end
  end
end
