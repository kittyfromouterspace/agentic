defmodule AgentEx.Telemetry.AggregatorTest do
  use ExUnit.Case, async: false

  alias AgentEx.Telemetry.Aggregator

  setup do
    Aggregator.reset()
    :ok
  end

  describe "summary/1" do
    test "returns empty map when no events" do
      assert Aggregator.summary(:default) == %{}
    end

    test "aggregates turn events by mode" do
      :telemetry.execute(
        [:agent_ex, :orchestration, :turn],
        %{},
        %{session_id: "s1", strategy: :default, mode: :agentic, phase: :execute, stop_reason: :end_turn}
      )

      :telemetry.execute(
        [:agent_ex, :orchestration, :turn],
        %{},
        %{session_id: "s1", strategy: :default, mode: :agentic, phase: :execute, stop_reason: :end_turn}
      )

      :telemetry.execute(
        [:agent_ex, :orchestration, :turn],
        %{},
        %{session_id: "s2", strategy: :default, mode: :conversational, phase: :execute, stop_reason: :end_turn}
      )

      result = Aggregator.summary(:default)

      assert result[:agentic].turn_count == 2
      assert result[:conversational].turn_count == 1
    end

    test "counts errors for max_tokens" do
      :telemetry.execute(
        [:agent_ex, :orchestration, :turn],
        %{},
        %{session_id: "s1", strategy: :default, mode: :agentic, phase: :execute, stop_reason: :max_tokens}
      )

      result = Aggregator.summary(:default, :agentic)
      assert result.turn_count == 1
      assert result.error_count == 1
    end
  end

  describe "summary/2" do
    test "returns empty entry for unknown strategy" do
      result = Aggregator.summary(:nonexistent, :agentic)
      assert result.turn_count == 0
    end

    test "aggregates tool events" do
      :telemetry.execute(
        [:agent_ex, :orchestration, :tool_executed],
        %{duration: 100, output_bytes: 50},
        %{session_id: "s1", strategy: :default, mode: :agentic, tool_name: "read_file", success: true}
      )

      :telemetry.execute(
        [:agent_ex, :orchestration, :tool_executed],
        %{duration: 200, output_bytes: 0},
        %{session_id: "s1", strategy: :default, mode: :agentic, tool_name: "bash", success: false}
      )

      result = Aggregator.summary(:default, :agentic)
      assert result.tool_call_count == 2
      assert result.tool_success_count == 1
      assert result.total_duration_ms == 300
    end
  end

  describe "reset/0" do
    test "clears all counters" do
      :telemetry.execute(
        [:agent_ex, :orchestration, :turn],
        %{},
        %{session_id: "s1", strategy: :default, mode: :agentic, phase: :execute, stop_reason: :end_turn}
      )

      assert Aggregator.summary(:default, :agentic).turn_count == 1

      Aggregator.reset()

      assert Aggregator.summary(:default) == %{}
    end
  end

  describe "tool events with mode" do
    test "groups tool events by mode" do
      :telemetry.execute(
        [:agent_ex, :orchestration, :tool_executed],
        %{duration: 100, output_bytes: 50},
        %{session_id: "s1", strategy: :default, mode: :agentic, tool_name: "read_file", success: true}
      )

      :telemetry.execute(
        [:agent_ex, :orchestration, :tool_executed],
        %{duration: 200, output_bytes: 0},
        %{session_id: "s1", strategy: :default, mode: :conversational, tool_name: "bash", success: true}
      )

      # Allow async GenServer cast to process
      Process.sleep(50)

      assert Aggregator.summary(:default, :agentic).tool_call_count == 1
      assert Aggregator.summary(:default, :conversational).tool_call_count == 1
    end
  end
end
