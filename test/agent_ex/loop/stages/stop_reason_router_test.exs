defmodule AgentEx.Loop.Stages.StopReasonRouterTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Stages.StopReasonRouter

  import AgentEx.TestHelpers

  defp passthrough, do: fn ctx -> {:ok, ctx} end

  describe "end_turn" do
    test "extracts text and passes to next stage" do
      ctx =
        build_ctx()
        |> Map.put(:last_response, %{
          "content" => [%{"type" => "text", "text" => "Here is the answer."}],
          "stop_reason" => "end_turn"
        })
        |> Map.put(:turns_used, 1)

      assert {:ok, result_ctx} = StopReasonRouter.call(ctx, passthrough())
      assert result_ctx.accumulated_text == "Here is the answer."
    end

    test "summary nudge fires when no text after tools" do
      # Simulate: turns > 0, no accumulated text, empty text in response
      reentry_called = :counters.new(1, [:atomics])

      reentry = fn ctx ->
        :counters.add(reentry_called, 1, 1)
        {:ok, ctx}
      end

      ctx =
        build_ctx()
        |> Map.put(:last_response, %{
          "content" => [%{"type" => "text", "text" => ""}],
          "stop_reason" => "end_turn"
        })
        |> Map.put(:turns_used, 1)
        |> Map.put(:accumulated_text, "")
        |> Map.put(:reentry_pipeline, reentry)

      assert {:ok, result_ctx} = StopReasonRouter.call(ctx, passthrough())
      assert result_ctx.summary_nudge_sent == true
      assert :counters.get(reentry_called, 1) == 1
    end
  end

  describe "tool_use" do
    test "stores pending_tool_calls" do
      ctx =
        build_ctx()
        |> Map.put(:last_response, %{
          "content" => [
            %{"type" => "text", "text" => "Let me read that."},
            %{
              "type" => "tool_use",
              "id" => "call_1",
              "name" => "read_file",
              "input" => %{"path" => "test.txt"}
            }
          ],
          "stop_reason" => "tool_use"
        })
        |> Map.put(:turns_used, 1)

      assert {:ok, result_ctx} = StopReasonRouter.call(ctx, passthrough())

      assert length(result_ctx.pending_tool_calls) == 1
      assert hd(result_ctx.pending_tool_calls)["name"] == "read_file"
    end
  end

  describe "max_tokens" do
    test "returns done with accumulated text" do
      ctx =
        build_ctx()
        |> Map.put(:last_response, %{
          "content" => [%{"type" => "text", "text" => "Partial response..."}],
          "stop_reason" => "max_tokens"
        })
        |> Map.put(:turns_used, 1)

      assert {:done, result} = StopReasonRouter.call(ctx, passthrough())
      assert result.text == "Partial response..."
    end
  end

  describe "max_turns safety rail" do
    test "fires when turns_used >= max_turns" do
      ctx =
        build_ctx()
        |> Map.put(:last_response, %{
          "content" => [
            %{"type" => "text", "text" => "More work to do."},
            %{
              "type" => "tool_use",
              "id" => "call_1",
              "name" => "bash",
              "input" => %{"command" => "ls"}
            }
          ],
          "stop_reason" => "tool_use"
        })
        |> Map.put(:turns_used, 50)
        |> Map.put(:config, %{max_turns: 50, telemetry_prefix: [:agent_ex]})

      assert {:done, result} = StopReasonRouter.call(ctx, passthrough())
      assert result.steps == 50
    end
  end

  describe "unknown stop reason" do
    test "treats as end_turn" do
      ctx =
        build_ctx()
        |> Map.put(:last_response, %{
          "content" => [%{"type" => "text", "text" => "Something happened."}],
          "stop_reason" => "unknown_reason"
        })

      assert {:done, result} = StopReasonRouter.call(ctx, passthrough())
      assert result.text == "Something happened."
    end
  end
end
