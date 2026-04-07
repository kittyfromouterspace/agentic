defmodule AgentEx.Loop.Stages.LLMCallCacheTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Stages.LLMCall

  import AgentEx.TestHelpers

  defp passthrough, do: fn ctx -> {:ok, ctx} end

  describe "cache awareness" do
    test "includes cache_control in params sent to llm_chat" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
        "cost" => 0.0
      }

      self_pid = self()

      llm_chat = fn params ->
        send(self_pid, {:params, params})
        {:ok, response}
      end

      ctx = build_ctx(callbacks: %{llm_chat: llm_chat})

      assert {:ok, _} = LLMCall.call(ctx, passthrough())

      assert_received {:params, params}
      assert %{"cache_control" => cc} = params
      assert is_binary(cc["stable_hash"])
      assert byte_size(cc["stable_hash"]) == 16
    end

    test "detects prefix change on first call (nil hash)" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "cost" => 0.0
      }

      self_pid = self()

      llm_chat = fn params ->
        send(self_pid, {:params, params})
        {:ok, response}
      end

      ctx = build_ctx(callbacks: %{llm_chat: llm_chat})

      assert {:ok, _} = LLMCall.call(ctx, passthrough())

      assert_received {:params, params}
      assert params["cache_control"]["prefix_changed"] == true
    end

    test "prefix_changed is false when hash matches stable_prefix_hash" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "cost" => 0.0
      }

      ctx = build_ctx(callbacks: %{llm_chat: fn _ -> {:ok, response} end})
      assert {:ok, ctx1} = LLMCall.call(ctx, passthrough())
      hash = ctx1.stable_prefix_hash
      assert is_binary(hash)

      assert {:ok, _ctx2} = LLMCall.call(ctx1, passthrough())

      self_pid = self()

      llm_chat = fn params ->
        send(self_pid, {:params, params})
        {:ok, response}
      end

      ctx1_with_hash = %{ctx1 | callbacks: %{llm_chat: llm_chat}}
      assert {:ok, _} = LLMCall.call(ctx1_with_hash, passthrough())

      assert_received {:params, params}
      assert params["cache_control"]["prefix_changed"] == false
    end

    test "stores stable_prefix_hash on context after call" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "cost" => 0.0
      }

      ctx = build_ctx(callbacks: %{llm_chat: fn _ -> {:ok, response} end})

      assert ctx.stable_prefix_hash == nil

      assert {:ok, result_ctx} = LLMCall.call(ctx, passthrough())
      assert is_binary(result_ctx.stable_prefix_hash)
      assert byte_size(result_ctx.stable_prefix_hash) == 16
    end

    test "hash changes when tool list changes" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "cost" => 0.0
      }

      ctx = build_ctx(callbacks: %{llm_chat: fn _ -> {:ok, response} end})
      assert {:ok, ctx1} = LLMCall.call(ctx, passthrough())

      ctx_with_extra_tool = %{ctx1 | tools: ctx1.tools ++ [%{"name" => "new_tool"}]}
      assert {:ok, ctx2} = LLMCall.call(ctx_with_extra_tool, passthrough())

      assert ctx1.stable_prefix_hash != ctx2.stable_prefix_hash
    end

    test "hash changes when system prompt changes" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "cost" => 0.0
      }

      ctx = build_ctx(callbacks: %{llm_chat: fn _ -> {:ok, response} end})
      assert {:ok, ctx1} = LLMCall.call(ctx, passthrough())

      new_messages = [
        %{"role" => "system", "content" => "Different system prompt."}
        | tl(ctx1.messages)
      ]

      ctx_changed = %{ctx1 | messages: new_messages}
      assert {:ok, ctx2} = LLMCall.call(ctx_changed, passthrough())

      assert ctx1.stable_prefix_hash != ctx2.stable_prefix_hash
    end
  end
end
