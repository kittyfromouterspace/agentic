defmodule Agentic.CLI.TranscriptTest do
  use ExUnit.Case, async: true

  describe "summarize_line(:opencode, line)" do
    test "step_start" do
      line = ~s({"type":"step_start","timestamp":1,"part":{"type":"step-start"}})
      assert {:step_start, ""} = Agentic.CLI.Transcript.summarize_line(:opencode, line)
    end

    test "text part" do
      line =
        ~s({"type":"text","part":{"type":"text","text":"helo world","time":{"end":1}}})

      assert {:text, "helo world"} = Agentic.CLI.Transcript.summarize_line(:opencode, line)
    end

    test "tool part with title and status" do
      line =
        ~s({"type":"tool","part":{"type":"tool","tool":"write","state":{"status":"completed","title":"blog/test.exs"}}})

      assert {:tool, "write — blog/test.exs — completed"} =
               Agentic.CLI.Transcript.summarize_line(:opencode, line)
    end

    test "tool_use envelope (top-level type) with input hint" do
      line =
        ~s({"type":"tool_use","part":{"type":"tool","tool":"glob","state":{"status":"completed","input":{"pattern":"**/*.ex"}}}})

      assert {:tool, "glob — pattern: **/*.ex — completed"} =
               Agentic.CLI.Transcript.summarize_line(:opencode, line)
    end

    test "step_finish with reason" do
      line = ~s({"type":"step_finish","part":{"type":"step-finish","reason":"stop","cost":0}})

      assert {:step_finish, "turn done · reason stop"} =
               Agentic.CLI.Transcript.summarize_line(:opencode, line)
    end

    test "error envelope" do
      line =
        ~s({"type":"error","error":{"type":"provider.quota","message":"Insufficient account funds"}})

      assert {:error, "provider.quota — Insufficient account funds"} =
               Agentic.CLI.Transcript.summarize_line(:opencode, line)
    end

    test "non-json line falls back to :raw" do
      assert :raw = Agentic.CLI.Transcript.summarize_line(:opencode, "--- Exit type: 0 ---")
    end
  end

  describe "summarize_line(:claude_code, line)" do
    test "system init with model" do
      line = ~s({"type":"system","subtype":"init","model":"claude-opus-5-5"})

      assert {:system, "session started · model claude-opus-5-5"} =
               Agentic.CLI.Transcript.summarize_line(:claude_code, line)
    end

    test "assistant text blocks" do
      line =
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}})

      assert {:text, "working on it"} =
               Agentic.CLI.Transcript.summarize_line(:claude_code, line)
    end

    test "assistant tool_use blocks" do
      line =
        ~s({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"mix test"}}]}})

      assert {:tool, "Bash — command: mix test"} =
               Agentic.CLI.Transcript.summarize_line(:claude_code, line)
    end

    test "result envelope" do
      line =
        ~s({"type":"result","subtype":"success","num_turns":1,"usage":{"total_cost_usd":0.01}})

      assert {:step_finish, "turn done · 1 turn(s) · cost $0.0100"} =
               Agentic.CLI.Transcript.summarize_line(:claude_code, line)
    end

    test "stream_event deltas are skipped" do
      line = ~s({"type":"stream_event","event":{"type":"content_block_delta"}})

      assert :skip = Agentic.CLI.Transcript.summarize_line(:claude_code, line)
    end

    test "error envelope" do
      line = ~s({"type":"error","error":{"message":"usage limit reached"}})

      assert {:error, "usage limit reached"} =
               Agentic.CLI.Transcript.summarize_line(:claude_code, line)
    end
  end

  test "unknown protocol falls back to :raw" do
    assert :raw = Agentic.CLI.Transcript.summarize_line(:codex, "{}")
  end

  describe "session_id/2" do
    test "extracts opencode session ids from event lines" do
      log = ~s({"type":"step_start","sessionID":"ses_e39d60551ffexChkJR6qloKERH"})
      assert Agentic.CLI.Transcript.session_id(:opencode, log) == "ses_e39d60551ffexChkJR6qloKERH"
    end

    test "extracts claude session ids from the init envelope" do
      log =
        ~s({"type":"system","subtype":"init","session_id":"61f2c8cf-9d2b-4fae-a72e-fdae3d5ce9d3"})

      assert Agentic.CLI.Transcript.session_id(:claude_code, log) ==
               "61f2c8cf-9d2b-4fae-a72e-fdae3d5ce9d3"
    end

    test "returns nil when the log has no native session id" do
      assert Agentic.CLI.Transcript.session_id(:opencode, "no json here") == nil
    end
  end
end
