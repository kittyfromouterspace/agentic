defmodule AgentEx.IntegrationTest do
  use ExUnit.Case, async: true

  import AgentEx.TestHelpers

  setup do
    AgentEx.CircuitBreaker.reset_all()
    :ok
  end

  describe "full agentic loop" do
    test "tool_use then end_turn" do
      turn = :counters.new(1, [:atomics])

      llm_chat = fn _params ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          # First call: return tool_use
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => "Let me read that file."},
               %{
                 "type" => "tool_use",
                 "id" => "call_1",
                 "name" => "read_file",
                 "input" => %{"path" => "test.txt"}
               }
             ],
             "stop_reason" => "tool_use",
             "usage" => %{"input_tokens" => 100, "output_tokens" => 80},
             "cost" => 0.002
           }}
        else
          # Second call: return end_turn
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "The file contains test data."}],
             "stop_reason" => "end_turn",
             "usage" => %{"input_tokens" => 200, "output_tokens" => 50},
             "cost" => 0.003
           }}
        end
      end

      workspace = create_test_workspace()
      File.write!(Path.join(workspace, "test.txt"), "hello world")

      execute_tool = fn "read_file", %{"path" => path}, ctx ->
        case File.read(Path.join(workspace, path)) do
          {:ok, content} -> {:ok, content, ctx}
          {:error, reason} -> {:error, inspect(reason)}
        end
      end

      assert {:ok, result} =
               AgentEx.run(
                 prompt: "Read test.txt",
                 workspace: workspace,
                 callbacks: %{llm_chat: llm_chat, execute_tool: execute_tool}
               )

      assert result.text == "The file contains test data."
      assert result.cost > 0
      assert result.cost == 0.005
      assert result.steps == 2
    end

    test "multiple tool calls in one turn" do
      turn = :counters.new(1, [:atomics])

      llm_chat = fn _params ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => "Let me read both files."},
               %{
                 "type" => "tool_use",
                 "id" => "call_1",
                 "name" => "read_file",
                 "input" => %{"path" => "a.txt"}
               },
               %{
                 "type" => "tool_use",
                 "id" => "call_2",
                 "name" => "read_file",
                 "input" => %{"path" => "b.txt"}
               }
             ],
             "stop_reason" => "tool_use",
             "usage" => %{"input_tokens" => 100, "output_tokens" => 80},
             "cost" => 0.002
           }}
        else
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Both files read successfully."}],
             "stop_reason" => "end_turn",
             "usage" => %{"input_tokens" => 200, "output_tokens" => 50},
             "cost" => 0.003
           }}
        end
      end

      workspace = create_test_workspace()

      execute_tool = fn "read_file", %{"path" => path}, ctx ->
        {:ok, "contents of #{path}", ctx}
      end

      assert {:ok, result} =
               AgentEx.run(
                 prompt: "Read a.txt and b.txt",
                 workspace: workspace,
                 callbacks: %{llm_chat: llm_chat, execute_tool: execute_tool}
               )

      assert result.text == "Both files read successfully."
      assert result.steps == 2
    end
  end

  describe "conversational loop" do
    test "simple end_turn" do
      workspace = create_test_workspace()

      assert {:ok, result} =
               AgentEx.run(
                 prompt: "Hello",
                 workspace: workspace,
                 profile: :conversational,
                 callbacks: %{llm_chat: &mock_llm_end_turn/1}
               )

      assert result.text == "Hello! I'm here to help."
      assert result.steps == 1
      assert result.cost == 0.001
    end
  end

  describe "error handling" do
    test "returns error when LLM fails" do
      workspace = create_test_workspace()

      assert {:error, :api_error} =
               AgentEx.run(
                 prompt: "Hello",
                 workspace: workspace,
                 callbacks: %{llm_chat: fn _ -> {:error, :api_error} end}
               )
    end
  end

  describe "cost limit" do
    test "stops when cost limit reached" do
      turn = :counters.new(1, [:atomics])

      llm_chat = fn _params ->
        :counters.add(turn, 1, 1)

        {:ok,
         %{
           "content" => [
             %{"type" => "text", "text" => "Working..."},
             %{
               "type" => "tool_use",
               "id" => "call_#{:counters.get(turn, 1)}",
               "name" => "bash",
               "input" => %{"command" => "echo hi"}
             }
           ],
           "stop_reason" => "tool_use",
           "usage" => %{"input_tokens" => 100, "output_tokens" => 80},
           "cost" => 3.0
         }}
      end

      workspace = create_test_workspace()

      execute_tool = fn _name, _input, ctx ->
        {:ok, "ok", ctx}
      end

      assert {:ok, result} =
               AgentEx.run(
                 prompt: "Do expensive work",
                 workspace: workspace,
                 cost_limit: 5.0,
                 callbacks: %{llm_chat: llm_chat, execute_tool: execute_tool}
               )

      # Should stop after hitting cost limit (ContextGuard fires)
      assert result.text =~ "cost limit"
    end
  end

  describe "events" do
    test "caller receives events" do
      workspace = create_test_workspace()

      turn = :counters.new(1, [:atomics])

      llm_chat = fn _params ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => "Checking."},
               %{
                 "type" => "tool_use",
                 "id" => "call_1",
                 "name" => "bash",
                 "input" => %{"command" => "echo hello"}
               }
             ],
             "stop_reason" => "tool_use",
             "usage" => %{"input_tokens" => 50, "output_tokens" => 30},
             "cost" => 0.001
           }}
        else
          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Done."}],
             "stop_reason" => "end_turn",
             "usage" => %{"input_tokens" => 50, "output_tokens" => 20},
             "cost" => 0.001
           }}
        end
      end

      execute_tool = fn _name, _input, ctx -> {:ok, "ok", ctx} end

      assert {:ok, _result} =
               AgentEx.run(
                 prompt: "Run something",
                 workspace: workspace,
                 caller: self(),
                 callbacks: %{llm_chat: llm_chat, execute_tool: execute_tool}
               )

      # Should have received tool_use events
      assert_received {:tool_use, "bash", _workspace_id}
      assert_received {:tool_use, nil, _workspace_id}
    end
  end
end
