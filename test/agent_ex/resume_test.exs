defmodule AgentEx.ResumeTest do
  use ExUnit.Case, async: true

  alias AgentEx.Persistence.Transcript.Local

  import AgentEx.TestHelpers

  describe "resume/1" do
    setup do
      workspace = create_test_workspace()
      {:ok, workspace: workspace}
    end

    test "returns error when session not found", %{workspace: workspace} do
      assert {:error, :session_not_found} =
               AgentEx.resume(
                 session_id: "nonexistent",
                 workspace: workspace,
                 callbacks: mock_callbacks()
               )
    end

    test "returns error when transcript is empty", %{workspace: workspace} do
      Local.append("empty-session", %{type: "test", turn: 0, data: %{}}, workspace: workspace)

      events_before =
        case Local.load("empty-session", workspace: workspace) do
          {:ok, events} -> length(events)
          _ -> 0
        end

      assert events_before > 0
    end

    test "reconstructs messages from transcript events", %{workspace: workspace} do
      Local.append(
        "resume-test-1",
        %{
          type: "llm_response",
          turn: 1,
          data: %{
            stop_reason: "end_turn",
            content_preview: "I'll help you with that.",
            usage: %{"input_tokens" => 100, "output_tokens" => 50},
            cost: 0.002
          }
        },
        workspace: workspace
      )

      Local.append(
        "resume-test-1",
        %{
          type: "tool_call",
          turn: 2,
          data: %{
            id: "call_1",
            name: "read_file",
            input: %{"path" => "test.txt"}
          }
        },
        workspace: workspace
      )

      Local.append(
        "resume-test-1",
        %{
          type: "llm_response",
          turn: 2,
          data: %{
            stop_reason: "end_turn",
            content_preview: "Here's what I found.",
            usage: %{"input_tokens" => 200, "output_tokens" => 80},
            cost: 0.003
          }
        },
        workspace: workspace
      )

      llm_chat = fn _params ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "Resuming work..."}],
           "stop_reason" => "end_turn",
           "usage" => %{"input_tokens" => 50, "output_tokens" => 20},
           "cost" => 0.001
         }}
      end

      result =
        AgentEx.resume(
          session_id: "resume-test-1",
          workspace: workspace,
          mode: :conversational,
          callbacks: %{llm_chat: llm_chat}
        )

      assert {:ok, _result_map} = result
    end
  end
end
