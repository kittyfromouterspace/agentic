defmodule AgentEx.Loop.Stages.ToolPermissionTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Stages.ToolExecutor

  import AgentEx.TestHelpers

  describe "tool permission gating" do
    test "allows tool when no permissions configured" do
      ctx = build_ctx()

      tool_calls = [
        %{
          "id" => "call_1",
          "name" => "read_file",
          "input" => %{"path" => "test.txt"}
        }
      ]

      ctx = %{ctx | pending_tool_calls: tool_calls, tool_permissions: %{}}

      result =
        ToolExecutor.call(ctx, fn ctx ->
          {:ok, ctx}
        end)

      assert {:ok, _} = result
    end

    test "denies tool when permission set to :deny" do
      ctx = build_ctx()

      tool_calls = [
        %{
          "id" => "call_1",
          "name" => "bash",
          "input" => %{"command" => "rm -rf /"}
        }
      ]

      ctx = %{ctx | pending_tool_calls: tool_calls, tool_permissions: %{"bash" => :deny}}

      {:ok, result_ctx} =
        ToolExecutor.call(ctx, fn ctx ->
          {:ok, ctx}
        end)

      last_msg = List.last(result_ctx.messages)
      assert last_msg["role"] == "user"

      tool_result =
        Enum.find(last_msg["content"], fn block ->
          block["type"] == "tool_result" && block["tool_use_id"] == "call_1"
        end)

      assert tool_result != nil
      assert tool_result["content"] =~ "not permitted"
      assert tool_result["is_error"] == true
    end

    test "allows tool when permission set to :auto" do
      ctx = build_ctx()

      tool_calls = [
        %{
          "id" => "call_1",
          "name" => "read_file",
          "input" => %{"path" => "test.txt"}
        }
      ]

      ctx = %{ctx | pending_tool_calls: tool_calls, tool_permissions: %{"read_file" => :auto}}

      result =
        ToolExecutor.call(ctx, fn ctx ->
          {:ok, ctx}
        end)

      assert {:ok, _} = result
    end

    test "calls on_tool_approval callback when permission is :approve" do
      self_pid = self()

      approval_callback = fn tool_name, input, _ctx ->
        send(self_pid, {:approval_requested, tool_name, input})
        :approved
      end

      ctx =
        build_ctx(callbacks: mock_callbacks(%{on_tool_approval: approval_callback}))

      tool_calls = [
        %{
          "id" => "call_1",
          "name" => "bash",
          "input" => %{"command" => "echo test"}
        }
      ]

      ctx = %{ctx | pending_tool_calls: tool_calls, tool_permissions: %{"bash" => :approve}}

      {:ok, _} =
        ToolExecutor.call(ctx, fn ctx ->
          {:ok, ctx}
        end)

      assert_received {:approval_requested, "bash", %{"command" => "echo test"}}
    end

    test "denies tool when on_tool_approval returns :denied" do
      approval_callback = fn _tool_name, _input, _ctx -> :denied end

      ctx =
        build_ctx(callbacks: mock_callbacks(%{on_tool_approval: approval_callback}))

      tool_calls = [
        %{
          "id" => "call_1",
          "name" => "bash",
          "input" => %{"command" => "echo test"}
        }
      ]

      ctx = %{ctx | pending_tool_calls: tool_calls, tool_permissions: %{"bash" => :approve}}

      {:ok, result_ctx} =
        ToolExecutor.call(ctx, fn ctx ->
          {:ok, ctx}
        end)

      last_msg = List.last(result_ctx.messages)
      tool_result = Enum.find(last_msg["content"], &(&1["tool_use_id"] == "call_1"))
      assert tool_result["is_error"] == true
    end

    test "allows tool with modified input when on_tool_approval returns {:approved_with_changes, new_input}" do
      self_pid = self()

      approval_callback = fn tool_name, _input, _ctx ->
        new_input = %{"command" => "echo modified"}
        send(self_pid, :approval_with_changes)
        {:approved_with_changes, new_input}
      end

      execute_fn = fn _name, input, ctx ->
        send(self_pid, {:executed_with, input})
        {:ok, "result", ctx}
      end

      ctx =
        build_ctx(
          callbacks:
            mock_callbacks(%{
              on_tool_approval: approval_callback,
              execute_tool: execute_fn
            })
        )

      tool_calls = [
        %{
          "id" => "call_1",
          "name" => "bash",
          "input" => %{"command" => "echo original"}
        }
      ]

      ctx = %{ctx | pending_tool_calls: tool_calls, tool_permissions: %{"bash" => :approve}}

      {:ok, _} =
        ToolExecutor.call(ctx, fn ctx ->
          {:ok, ctx}
        end)

      assert_received :approval_with_changes
      assert_received {:executed_with, %{"command" => "echo modified"}}
    end

    test "falls back to approved when on_tool_approval callback raises" do
      approval_callback = fn _tool_name, _input, _ctx -> raise "oops" end

      ctx =
        build_ctx(callbacks: mock_callbacks(%{on_tool_approval: approval_callback}))

      tool_calls = [
        %{
          "id" => "call_1",
          "name" => "bash",
          "input" => %{"command" => "echo test"}
        }
      ]

      ctx = %{ctx | pending_tool_calls: tool_calls, tool_permissions: %{"bash" => :approve}}

      {:ok, result_ctx} =
        ToolExecutor.call(ctx, fn ctx ->
          {:ok, ctx}
        end)

      last_msg = List.last(result_ctx.messages)
      tool_result = Enum.find(last_msg["content"], &(&1["tool_use_id"] == "call_1"))
      assert tool_result["is_error"] != true
    end

    test "passes through when no pending tool calls" do
      ctx = build_ctx(tool_permissions: %{"bash" => :deny})

      assert {:ok, ctx} =
               ToolExecutor.call(ctx, fn ctx ->
                 {:ok, ctx}
               end)
    end
  end
end
