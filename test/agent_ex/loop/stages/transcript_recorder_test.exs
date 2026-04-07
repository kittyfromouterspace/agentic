defmodule AgentEx.Loop.Stages.TranscriptRecorderTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Stages.TranscriptRecorder
  alias AgentEx.Persistence.Transcript.Local

  import AgentEx.TestHelpers

  defp passthrough, do: fn ctx -> {:ok, ctx} end

  describe "call/2" do
    setup do
      workspace = create_test_workspace()
      {:ok, workspace: workspace}
    end

    test "records llm_response event when backend is configured", %{workspace: workspace} do
      response = %{
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50},
        "cost" => 0.002
      }

      ctx =
        build_ctx(
          session_id: "rec-test-1",
          callbacks: mock_callbacks(),
          metadata: %{workspace: workspace}
        )

      ctx = %{
        ctx
        | last_response: response,
          turns_used: 1,
          callbacks: Map.put(ctx.callbacks, :transcript_backend, Local)
      }

      assert {:ok, result_ctx} = TranscriptRecorder.call(ctx, passthrough())
      assert result_ctx == ctx

      {:ok, events} = Local.load("rec-test-1", workspace: workspace)
      assert length(events) >= 1

      llm_event = Enum.find(events, &(&1["type"] == "llm_response"))
      assert llm_event != nil
      assert llm_event["turn"] == 1
      assert llm_event["data"]["stop_reason"] == "end_turn"
    end

    test "records tool_call events for pending tool calls", %{workspace: workspace} do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Checking file."},
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "read_file",
            "input" => %{"path" => "a.txt"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{},
        "cost" => 0.0
      }

      ctx =
        build_ctx(
          session_id: "rec-test-2",
          callbacks: mock_callbacks(),
          metadata: %{workspace: workspace}
        )

      ctx = %{
        ctx
        | last_response: response,
          turns_used: 1,
          pending_tool_calls: [
            %{"id" => "call_1", "name" => "read_file", "input" => %{"path" => "a.txt"}}
          ],
          callbacks: Map.put(ctx.callbacks, :transcript_backend, Local)
      }

      assert {:ok, _} = TranscriptRecorder.call(ctx, passthrough())

      {:ok, events} = Local.load("rec-test-2", workspace: workspace)
      tool_event = Enum.find(events, &(&1["type"] == "tool_call"))
      assert tool_event != nil
      assert tool_event["data"]["name"] == "read_file"
    end

    test "is no-op when no transcript_backend callback" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "cost" => 0.0
      }

      ctx = build_ctx()
      ctx = %{ctx | last_response: response, turns_used: 1}

      assert {:ok, result_ctx} = TranscriptRecorder.call(ctx, passthrough())
      assert result_ctx.turns_used == 1
    end

    test "is no-op when last_response is nil" do
      ctx = build_ctx(callbacks: Map.put(mock_callbacks(), :transcript_backend, Local))

      assert {:ok, result_ctx} = TranscriptRecorder.call(ctx, passthrough())
      assert result_ctx == ctx
    end

    test "is no-op when workspace is missing" do
      response = %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{},
        "cost" => 0.0
      }

      ctx =
        build_ctx(
          callbacks: Map.put(mock_callbacks(), :transcript_backend, Local),
          metadata: %{}
        )

      ctx = %{ctx | last_response: response, turns_used: 1}

      assert {:ok, _} = TranscriptRecorder.call(ctx, passthrough())
    end
  end
end
