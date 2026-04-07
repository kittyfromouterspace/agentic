defmodule AgentEx.Subagent.CoordinatorTest do
  use ExUnit.Case

  alias AgentEx.Subagent.Coordinator
  alias AgentEx.Subagent.CoordinatorSupervisor

  import AgentEx.TestHelpers

  describe "ensure_started/1" do
    test "starts a coordinator for a workspace" do
      workspace = create_test_workspace()
      unique_ws = "#{workspace}-coord-test-#{:rand.uniform(100_000)}"

      assert {:ok, pid} = Coordinator.ensure_started(unique_ws)
      assert is_pid(pid)
      assert Process.alive?(pid)

      assert {:ok, pid2} = Coordinator.ensure_started(unique_ws)
      assert pid2 == pid
    end
  end

  describe "spawn_subagent/3" do
    test "spawns a subagent and returns result" do
      workspace = create_test_workspace()
      unique_ws = "#{workspace}-spawn-test-#{:rand.uniform(100_000)}"

      callbacks = %{
        llm_chat: fn _params ->
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Subagent completed the task."}],
             "stop_reason" => "end_turn",
             "usage" => %{"input_tokens" => 50, "output_tokens" => 20},
             "cost" => 0.001
           }}
        end,
        execute_tool: fn name, _input, ctx -> {:ok, "mock result", ctx} end
      }

      result =
        Coordinator.spawn_subagent(
          unique_ws,
          "Check if the project has a README",
          parent_session_id: "parent-1",
          subagent_depth: 0,
          max_turns: 5,
          callbacks: callbacks
        )

      assert {:ok, %{text: _, cost: _, steps: _, tokens: _}} = result
    end

    test "respects max concurrent limit" do
      workspace = create_test_workspace()
      unique_ws = "#{workspace}-limit-test-#{:rand.uniform(100_000)}"

      blocking_callbacks = %{
        llm_chat: fn _params ->
          Process.sleep(1000)

          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "done"}],
             "stop_reason" => "end_turn",
             "usage" => %{},
             "cost" => 0.0
           }}
        end,
        execute_tool: fn _, _, ctx -> {:ok, "mock", ctx} end
      }

      tasks =
        for i <- 1..6 do
          Task.async(fn ->
            Coordinator.spawn_subagent(
              unique_ws,
              "Task #{i}",
              parent_session_id: "parent-limit",
              subagent_depth: 0,
              max_turns: 2,
              callbacks: blocking_callbacks
            )
          end)
        end

      results = Task.await_many(tasks, 30_000)

      error_results =
        Enum.filter(results, fn
          {:error, :max_concurrent_reached} -> true
          _ -> false
        end)

      assert length(error_results) >= 1
    end
  end

  describe "list_subagents/1" do
    test "returns empty list when no coordinator exists" do
      assert {:ok, []} =
               Coordinator.list_subagents("nonexistent-workspace-#{:rand.uniform(999_999)}")
    end
  end
end
