defmodule AgentEx.Loop.EngineTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Engine

  import AgentEx.TestHelpers

  defmodule AppendA do
    @behaviour AgentEx.Loop.Stage

    @impl true
    def call(ctx, next) do
      ctx = %{ctx | accumulated_text: ctx.accumulated_text <> "A"}
      next.(ctx)
    end
  end

  defmodule AppendB do
    @behaviour AgentEx.Loop.Stage

    @impl true
    def call(ctx, next) do
      ctx = %{ctx | accumulated_text: ctx.accumulated_text <> "B"}
      next.(ctx)
    end
  end

  defmodule DoneStage do
    @behaviour AgentEx.Loop.Stage

    @impl true
    def call(ctx, _next) do
      {:done, %{text: ctx.accumulated_text <> "DONE", cost: ctx.total_cost, tokens: 0, steps: 0}}
    end
  end

  defmodule RaisingStage do
    @behaviour AgentEx.Loop.Stage

    @impl true
    def call(_ctx, _next) do
      raise "boom!"
    end
  end

  describe "run/2" do
    test "runs stages in order" do
      ctx = build_ctx()
      assert {:ok, result} = Engine.run(ctx, [AppendA, AppendB])
      assert result.text == "AB"
    end

    test "pipeline terminates on {:done, result}" do
      ctx = build_ctx()
      assert {:ok, result} = Engine.run(ctx, [AppendA, DoneStage, AppendB])
      # DoneStage short-circuits, AppendB never runs
      assert result.text == "ADONE"
    end

    test "handles empty stage list" do
      ctx = build_ctx()
      assert {:ok, result} = Engine.run(ctx, [])
      assert result.text == ""
      assert result.steps == 0
    end

    test "rescues stage errors" do
      ctx = build_ctx()
      assert {:error, "boom!"} = Engine.run(ctx, [RaisingStage])
    end
  end

  describe "build_pipeline/1" do
    test "returns a function" do
      pipeline = Engine.build_pipeline([AppendA])
      assert is_function(pipeline, 1)
    end

    test "pipeline with no stages returns done with context result" do
      pipeline = Engine.build_pipeline([])
      ctx = build_ctx()
      assert {:done, result} = pipeline.(ctx)
      assert result.text == ""
    end
  end
end
