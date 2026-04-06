defmodule AgentEx.Loop.Stages.LLMCallTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Stages.LLMCall

  import AgentEx.TestHelpers

  defp passthrough, do: fn ctx -> {:ok, ctx} end

  describe "call/2" do
    test "calls llm_chat callback and stores response" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Hello there."}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 50, "output_tokens" => 30},
        "cost" => 0.0005
      }

      ctx = build_ctx(callbacks: %{llm_chat: fn _params -> {:ok, response} end})

      assert {:ok, result_ctx} = LLMCall.call(ctx, passthrough())
      assert result_ctx.last_response == response
      assert result_ctx.turns_used == 1
    end

    test "tracks usage from response" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50},
        "cost" => 0.002
      }

      ctx = build_ctx(callbacks: %{llm_chat: fn _ -> {:ok, response} end})

      assert {:ok, result_ctx} = LLMCall.call(ctx, passthrough())
      assert result_ctx.total_cost == 0.002
      assert result_ctx.total_tokens == 150
    end

    test "returns error when llm_chat fails" do
      ctx = build_ctx(callbacks: %{llm_chat: fn _ -> {:error, :rate_limited} end})

      assert {:error, :rate_limited} = LLMCall.call(ctx, passthrough())
    end

    test "returns error when no llm_chat callback" do
      ctx = build_ctx(callbacks: %{})

      assert {:error, :no_llm_adapter} = LLMCall.call(ctx, passthrough())
    end

    test "increments turns_used" do
      response = %{
        "content" => [],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 0, "output_tokens" => 0},
        "cost" => 0.0
      }

      ctx = build_ctx(callbacks: %{llm_chat: fn _ -> {:ok, response} end})
      ctx = %{ctx | turns_used: 5}

      assert {:ok, result_ctx} = LLMCall.call(ctx, passthrough())
      assert result_ctx.turns_used == 6
    end
  end
end
