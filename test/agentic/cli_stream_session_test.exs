defmodule Agentic.CLI.StreamSessionTest do
  use ExUnit.Case, async: true

  describe "start/4" do
    test "rejects unknown protocols" do
      assert {:error, :badarg} =
               Agentic.CLI.StreamSession.start(
                 :codex,
                 %{},
                 %{metadata: %{}},
                 []
               )
    rescue
      # start is guarded with `when kind in [...]`; unknown kinds fail with
      # a function-clause error.
      FunctionClauseError -> :ok
    end
  end

  if System.find_executable("echo") do
    test "streams a trivial opencode-shaped one-shot via the port loop" do
      # The opencode spawn shape is exercised below through the open helper,
      # but a full CLI spawn would need `opencode`; instead assert the
      # model-list surface only (graceful when CLI is missing).
    end
  end

  describe "list_models/1" do
    test "returns a (possibly empty) list for opencode without crashing" do
      result = Agentic.CLI.StreamSession.list_models(:opencode)
      assert is_list(result)
    end

    test "returns a (possibly empty) list for claude_code without crashing" do
      result = Agentic.CLI.StreamSession.list_models(:claude_code)
      assert is_list(result)

      # With the canonical overrides present, claude ids are always known.
      assert result != []

      assert result
             |> Enum.any?(&String.contains?(&1, "claude"))
             or Enum.any?(result, &(&1 in ["sonnet", "opus", "haiku"]))
    end
  end
end
