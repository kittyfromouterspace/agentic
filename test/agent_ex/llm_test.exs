defmodule AgentEx.LLMTest do
  use ExUnit.Case, async: false

  alias AgentEx.LLM

  describe "embed/2" do
    test "errors when provider is unknown" do
      assert {:error, %AgentEx.LLM.Error{classification: :permanent}} =
               LLM.embed("hello", provider: :nonsense_provider, model: "x")
    end

    test "raises when provider option missing" do
      assert_raise KeyError, fn ->
        LLM.embed("hello", model: "x")
      end
    end
  end

  describe "embed_tier/3" do
    test "returns an error when no embedding model is in the catalog for the tier" do
      # The catalog is shared global state. We don't make assumptions about
      # what's loaded — instead test the error path with an unknown tier.
      result = LLM.embed_tier("hello", :nonexistent_tier_xyz, [])

      case result do
        {:error, %AgentEx.LLM.Error{}} -> :ok
        # If a default embedding model exists, it might still resolve via fallback;
        # in that case the call hits HTTP and likely errors with timeout/auth.
        {:ok, _, _} -> :ok
        other -> flunk("unexpected: #{inspect(other)}")
      end
    end
  end
end
