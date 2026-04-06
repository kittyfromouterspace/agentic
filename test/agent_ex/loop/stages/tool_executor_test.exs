defmodule AgentEx.Loop.Stages.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Stages.ToolExecutor
  alias AgentEx.CircuitBreaker

  import AgentEx.TestHelpers

  setup do
    CircuitBreaker.reset_all()
    :ok
  end

  defp passthrough, do: fn ctx -> {:ok, ctx} end

  describe "call/2" do
    test "executes pending tool calls via callback" do
      tool_calls = [
        %{"id" => "call_1", "name" => "read_file", "input" => %{"path" => "test.txt"}}
      ]

      execute_tool = fn "read_file", _input, ctx ->
        {:ok, "file contents here", ctx}
      end

      ctx =
        build_ctx(callbacks: %{llm_chat: &mock_llm_end_turn/1, execute_tool: execute_tool})
        |> Map.put(:pending_tool_calls, tool_calls)
        |> Map.put(:reentry_pipeline, fn ctx -> {:ok, ctx} end)

      assert {:ok, result_ctx} = ToolExecutor.call(ctx, passthrough())
      assert result_ctx.pending_tool_calls == []

      # Tool result should be appended to messages
      last_msg = List.last(result_ctx.messages)
      assert last_msg["role"] == "user"
      [block] = last_msg["content"]
      assert block["tool_use_id"] == "call_1"
      assert block["content"] == "file contents here"
    end

    test "passes through when no pending calls" do
      ctx = build_ctx()
      assert ctx.pending_tool_calls == []

      assert {:ok, result_ctx} = ToolExecutor.call(ctx, passthrough())
      assert result_ctx.pending_tool_calls == []
    end

    test "handles tool errors gracefully" do
      tool_calls = [
        %{"id" => "call_1", "name" => "broken_tool", "input" => %{}}
      ]

      execute_tool = fn "broken_tool", _input, _ctx ->
        {:error, "something went wrong"}
      end

      ctx =
        build_ctx(callbacks: %{llm_chat: &mock_llm_end_turn/1, execute_tool: execute_tool})
        |> Map.put(:pending_tool_calls, tool_calls)
        |> Map.put(:reentry_pipeline, fn ctx -> {:ok, ctx} end)

      assert {:ok, result_ctx} = ToolExecutor.call(ctx, passthrough())

      last_msg = List.last(result_ctx.messages)
      [block] = last_msg["content"]
      assert block["is_error"] == true
      assert block["content"] == "something went wrong"
    end

    test "circuit breaker blocks after failures" do
      # Trip the circuit breaker for a tool
      CircuitBreaker.record_failure("flaky_tool")
      CircuitBreaker.record_failure("flaky_tool")
      CircuitBreaker.record_failure("flaky_tool")

      assert CircuitBreaker.get_state("flaky_tool") == :open

      tool_calls = [
        %{"id" => "call_1", "name" => "flaky_tool", "input" => %{}}
      ]

      execute_tool = fn _name, _input, ctx ->
        {:ok, "should not reach here", ctx}
      end

      ctx =
        build_ctx(callbacks: %{llm_chat: &mock_llm_end_turn/1, execute_tool: execute_tool})
        |> Map.put(:pending_tool_calls, tool_calls)
        |> Map.put(:reentry_pipeline, fn ctx -> {:ok, ctx} end)

      assert {:ok, result_ctx} = ToolExecutor.call(ctx, passthrough())

      last_msg = List.last(result_ctx.messages)
      [block] = last_msg["content"]
      assert block["is_error"] == true
      assert block["content"] =~ "temporarily unavailable"
    end

    test "handles tool that raises an exception" do
      tool_calls = [
        %{"id" => "call_1", "name" => "crasher", "input" => %{}}
      ]

      execute_tool = fn "crasher", _input, _ctx ->
        raise "kaboom"
      end

      ctx =
        build_ctx(callbacks: %{llm_chat: &mock_llm_end_turn/1, execute_tool: execute_tool})
        |> Map.put(:pending_tool_calls, tool_calls)
        |> Map.put(:reentry_pipeline, fn ctx -> {:ok, ctx} end)

      assert {:ok, result_ctx} = ToolExecutor.call(ctx, passthrough())

      last_msg = List.last(result_ctx.messages)
      [block] = last_msg["content"]
      assert block["is_error"] == true
      assert block["content"] =~ "kaboom"
    end
  end
end
