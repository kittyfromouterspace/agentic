defmodule AgentExTest do
  use ExUnit.Case

  test "run/1 requires prompt, workspace, and callbacks" do
    assert_raise KeyError, ~r/key :prompt not found/, fn ->
      AgentEx.run([])
    end
  end
end
