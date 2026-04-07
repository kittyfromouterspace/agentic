defmodule AgentEx.Subagent.DelegateTaskTest do
  use ExUnit.Case, async: true

  alias AgentEx.Subagent.DelegateTask

  import AgentEx.TestHelpers

  describe "definition/0" do
    test "returns valid tool definition map" do
      defn = DelegateTask.definition()

      assert defn["name"] == "delegate_task"
      assert is_map(defn["input_schema"])
      assert defn["input_schema"]["type"] == "object"
      assert "task" in defn["input_schema"]["required"]
    end
  end

  describe "execute/2" do
    test "returns error when at max depth" do
      ctx = build_ctx()
      ctx = %{ctx | subagent_depth: 3}

      assert {:error, msg} = DelegateTask.execute(%{"task" => "do something"}, ctx)
      assert msg =~ "maximum subagent nesting depth"
    end

    test "returns error when task is empty" do
      ctx = build_ctx()

      assert {:error, msg} = DelegateTask.execute(%{"task" => ""}, ctx)
      assert msg =~ "required"
    end

    test "returns error when task is nil" do
      ctx = build_ctx()

      assert {:error, msg} = DelegateTask.execute(%{}, ctx)
      assert msg =~ "required"
    end

    test "returns error when no workspace configured" do
      ctx = build_ctx(metadata: %{})

      assert {:error, msg} = DelegateTask.execute(%{"task" => "read README"}, ctx)
      assert msg =~ "No workspace"
    end
  end
end
