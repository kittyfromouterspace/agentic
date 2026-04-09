defmodule AgentEx.LLM.ErrorPatternsTest do
  use ExUnit.Case, async: true

  alias AgentEx.LLM.ErrorPatterns

  describe "classify_message/1 — :rate_limit" do
    test "matches rate_limit" do
      assert ErrorPatterns.classify_message("You hit the rate_limit") == :rate_limit
    end

    test "matches rate limit (space)" do
      assert ErrorPatterns.classify_message("rate limit exceeded") == :rate_limit
    end

    test "matches too many requests" do
      assert ErrorPatterns.classify_message("Too many requests") == :rate_limit
    end

    test "matches 429" do
      assert ErrorPatterns.classify_message("HTTP 429 error") == :rate_limit
    end

    test "matches throttling" do
      assert ErrorPatterns.classify_message("Request was throttled") == :rate_limit
    end

    test "matches throttlingexception" do
      assert ErrorPatterns.classify_message("ThrottlingException: rate exceeded") == :rate_limit
    end

    test "matches quota exceeded" do
      assert ErrorPatterns.classify_message("You have quota exceeded for this API") == :rate_limit
    end

    test "matches resource_exhausted" do
      assert ErrorPatterns.classify_message("resource_exhausted") == :rate_limit
    end

    test "matches tokens per minute" do
      assert ErrorPatterns.classify_message("You exceeded tokens per minute limit") == :rate_limit
    end

    test "matches TPM" do
      assert ErrorPatterns.classify_message("TPM limit reached") == :rate_limit
    end
  end

  describe "classify_message/1 — :overloaded" do
    test "matches overloaded" do
      assert ErrorPatterns.classify_message("The API is overloaded") == :overloaded
    end

    test "matches overloaded_error" do
      assert ErrorPatterns.classify_message("overloaded_error: try again") == :overloaded
    end

    test "matches high demand" do
      assert ErrorPatterns.classify_message("Server experiencing high demand") == :overloaded
    end

    test "matches service_unavailable with capacity" do
      assert ErrorPatterns.classify_message("service_unavailable due to capacity") == :overloaded
    end
  end

  describe "classify_message/1 — :billing" do
    test "matches insufficient credits" do
      assert ErrorPatterns.classify_message("insufficient credits") == :billing
    end

    test "matches insufficient_quota" do
      assert ErrorPatterns.classify_message("insufficient_quota: check your plan") == :billing
    end

    test "matches payment required" do
      assert ErrorPatterns.classify_message("payment required") == :billing
    end

    test "matches credit balance" do
      assert ErrorPatterns.classify_message("check your credit balance") == :billing
    end
  end

  describe "classify_message/1 — :auth_permanent" do
    test "matches api key revoked" do
      assert ErrorPatterns.classify_message("api_key_revoked") == :auth_permanent
    end

    test "matches key has been disabled" do
      assert ErrorPatterns.classify_message("key has been disabled") == :auth_permanent
    end

    test "matches account has been deactivated" do
      assert ErrorPatterns.classify_message("account has been deactivated") == :auth_permanent
    end

    test "matches not allowed for this organization" do
      assert ErrorPatterns.classify_message("not allowed for this organization") ==
               :auth_permanent
    end
  end

  describe "classify_message/1 — :auth" do
    test "matches invalid api key" do
      assert ErrorPatterns.classify_message("invalid api key") == :auth
    end

    test "matches invalid_api_key" do
      assert ErrorPatterns.classify_message("invalid_api_key") == :auth
    end

    test "matches unauthorized" do
      assert ErrorPatterns.classify_message("unauthorized access") == :auth
    end

    test "matches 401" do
      assert ErrorPatterns.classify_message("error 401") == :auth
    end

    test "matches 403" do
      assert ErrorPatterns.classify_message("error 403 forbidden") == :auth
    end

    test "matches no api key found" do
      assert ErrorPatterns.classify_message("no api key found") == :auth
    end
  end

  describe "classify_message/1 — :timeout" do
    test "matches timeout" do
      assert ErrorPatterns.classify_message("Request timeout") == :timeout
    end

    test "matches connection error" do
      assert ErrorPatterns.classify_message("connection error") == :timeout
    end

    test "matches econnrefused" do
      assert ErrorPatterns.classify_message("econnrefused 127.0.0.1:443") == :timeout
    end

    test "matches etimedout" do
      assert ErrorPatterns.classify_message("etimedout") == :timeout
    end

    test "matches network error" do
      assert ErrorPatterns.classify_message("network error") == :timeout
    end
  end

  describe "classify_message/1 — :format" do
    test "matches tool_use.id" do
      assert ErrorPatterns.classify_message("tool_use.id must be a string") == :format
    end

    test "matches invalid request format" do
      assert ErrorPatterns.classify_message("invalid request format") == :format
    end
  end

  describe "classify_message/1 — :model_not_found" do
    test "matches model_is_deactivated" do
      assert ErrorPatterns.classify_message("model_is_deactivated") == :model_not_found
    end

    test "matches model not found" do
      assert ErrorPatterns.classify_message("model not found") == :model_not_found
    end
  end

  describe "classify_message/1 — :context_overflow" do
    test "matches input token count exceeds" do
      msg = "input token count exceeds the maximum number of input tokens"
      assert ErrorPatterns.classify_message(msg) == :context_overflow
    end

    test "matches input is too long for this model" do
      assert ErrorPatterns.classify_message("input is too long for this model") ==
               :context_overflow
    end

    test "matches ollama context length exceeded" do
      assert ErrorPatterns.classify_message("ollama error: context length exceeded") ==
               :context_overflow
    end

    test "matches generic heuristic — tokens + exceeds" do
      assert ErrorPatterns.classify_message("tokens exceeds maximum limit") == :context_overflow
    end

    test "matches generic heuristic — context + too large" do
      assert ErrorPatterns.classify_message("context window too large") == :context_overflow
    end
  end

  describe "classify_message/1 — priority" do
    test "billing takes priority over auth" do
      msg = "insufficient credits, unauthorized access"
      assert ErrorPatterns.classify_message(msg) == :billing
    end

    test "auth_permanent takes priority over auth" do
      msg = "api_key_revoked unauthorized"
      assert ErrorPatterns.classify_message(msg) == :auth_permanent
    end
  end

  describe "classify_message/1 — nil for unknown" do
    test "returns nil for unrecognized messages" do
      assert ErrorPatterns.classify_message("something completely random") == nil
    end

    test "returns nil for nil" do
      assert ErrorPatterns.classify_message(nil) == nil
    end
  end
end
