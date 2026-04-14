defmodule AgentEx.Loop.ContextTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Context

  describe "new/1" do
    test "creates context with defaults" do
      ctx = Context.new([])

      assert ctx.session_id == nil
      assert ctx.user_id == nil
      assert ctx.caller == nil
      assert ctx.metadata == %{}
      assert ctx.messages == []
      assert ctx.tools == []
      assert ctx.core_tools == []
      assert ctx.model_tier == :primary
      assert ctx.callbacks == %{}
      assert ctx.total_cost == 0.0
      assert ctx.total_tokens == 0
      assert ctx.turns_used == 0
      assert ctx.accumulated_text == ""
      assert ctx.pending_tool_calls == []
      assert ctx.phase == :execute
      assert ctx.strategy == :default
    end

    test "creates context with provided values" do
      ctx =
        Context.new(
          session_id: "sess-1",
          user_id: "user-1",
          caller: self(),
          metadata: %{workspace: "/tmp"},
          messages: [%{"role" => "system", "content" => "hi"}],
          model_tier: :lightweight,
          strategy: :stigmergy,
          callbacks: %{llm_chat: fn _ -> :ok end}
        )

      assert ctx.session_id == "sess-1"
      assert ctx.user_id == "user-1"
      assert ctx.caller == self()
      assert ctx.metadata == %{workspace: "/tmp"}
      assert length(ctx.messages) == 1
      assert ctx.model_tier == :lightweight
      assert ctx.strategy == :stigmergy
      assert is_function(ctx.callbacks[:llm_chat])
    end
  end

  describe "track_usage/2" do
    test "accumulates cost and tokens" do
      ctx = Context.new([])

      resp1 = %AgentEx.LLM.Response{
        cost: 0.001,
        usage: %{input_tokens: 100, output_tokens: 50, cache_read: 0, cache_write: 0}
      }

      ctx = Context.track_usage(ctx, resp1)
      assert ctx.total_cost == 0.001
      assert ctx.total_tokens == 150

      resp2 = %AgentEx.LLM.Response{
        cost: 0.002,
        usage: %{input_tokens: 200, output_tokens: 100, cache_read: 0, cache_write: 0}
      }

      ctx = Context.track_usage(ctx, resp2)
      assert ctx.total_cost == 0.003
      assert ctx.total_tokens == 450
    end

    test "handles missing cost and usage gracefully" do
      ctx = Context.new([])

      ctx = Context.track_usage(ctx, %AgentEx.LLM.Response{})
      assert ctx.total_cost == 0.0
      assert ctx.total_tokens == 0
    end
  end

  describe "emit_event/2" do
    test "sends event to caller" do
      ctx = Context.new(caller: self())
      Context.emit_event(ctx, {:test_event, "hello"})
      assert_receive {:test_event, "hello"}
    end

    test "calls on_event callback" do
      test_pid = self()

      ctx =
        Context.new(
          caller: nil,
          callbacks: %{
            on_event: fn event, _ctx -> send(test_pid, {:callback_event, event}) end
          }
        )

      Context.emit_event(ctx, :some_event)
      assert_receive {:callback_event, :some_event}
    end

    test "handles nil caller without error" do
      ctx = Context.new(caller: nil)
      assert Context.emit_event(ctx, :whatever) == :ok
    end
  end
end
