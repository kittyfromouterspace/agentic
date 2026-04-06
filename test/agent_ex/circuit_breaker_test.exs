defmodule AgentEx.CircuitBreakerTest do
  # Not async because CircuitBreaker uses a shared ETS table
  use ExUnit.Case, async: false

  alias AgentEx.CircuitBreaker

  setup do
    CircuitBreaker.reset_all()
    :ok
  end

  describe "get_state/1" do
    test "starts closed for unknown tools" do
      assert CircuitBreaker.get_state("new_tool") == :closed
    end
  end

  describe "check/1" do
    test "returns :ok when closed" do
      assert CircuitBreaker.check("some_tool") == :ok
    end

    test "returns :ok when half_open" do
      # Trip it open
      CircuitBreaker.record_failure("tool_a")
      CircuitBreaker.record_failure("tool_a")
      CircuitBreaker.record_failure("tool_a")
      assert CircuitBreaker.get_state("tool_a") == :open

      # Simulate cooldown expiry by inserting a record with a sufficiently old timestamp
      old_ts = System.monotonic_time(:millisecond) - 400_000
      :ets.insert(:agent_ex_circuit_breaker, {"tool_a", :open, 3, old_ts})
      assert CircuitBreaker.get_state("tool_a") == :half_open
      assert CircuitBreaker.check("tool_a") == :ok
    end
  end

  describe "record_failure/1" do
    test "opens after threshold failures" do
      CircuitBreaker.record_failure("fragile")
      assert CircuitBreaker.get_state("fragile") == :closed

      CircuitBreaker.record_failure("fragile")
      assert CircuitBreaker.get_state("fragile") == :closed

      CircuitBreaker.record_failure("fragile")
      assert CircuitBreaker.get_state("fragile") == :open
    end

    test "returns {:error, :circuit_open} when open" do
      CircuitBreaker.record_failure("blocked")
      CircuitBreaker.record_failure("blocked")
      CircuitBreaker.record_failure("blocked")

      assert {:error, :circuit_open} = CircuitBreaker.check("blocked")
    end
  end

  describe "record_success/1" do
    test "resets failure count" do
      CircuitBreaker.record_failure("resettable")
      CircuitBreaker.record_failure("resettable")
      # 2 failures, not tripped yet
      assert CircuitBreaker.get_state("resettable") == :closed

      CircuitBreaker.record_success("resettable")
      assert CircuitBreaker.get_state("resettable") == :closed

      # After reset, needs 3 more failures to trip
      CircuitBreaker.record_failure("resettable")
      CircuitBreaker.record_failure("resettable")
      assert CircuitBreaker.get_state("resettable") == :closed
    end

    test "closes from half_open on success" do
      # Trip it open, then simulate cooldown
      CircuitBreaker.record_failure("recovering")
      CircuitBreaker.record_failure("recovering")
      CircuitBreaker.record_failure("recovering")
      assert CircuitBreaker.get_state("recovering") == :open

      # Simulate cooldown expiry
      old_ts = System.monotonic_time(:millisecond) - 400_000
      :ets.insert(:agent_ex_circuit_breaker, {"recovering", :open, 3, old_ts})
      assert CircuitBreaker.get_state("recovering") == :half_open

      CircuitBreaker.record_success("recovering")
      assert CircuitBreaker.get_state("recovering") == :closed
    end
  end

  describe "half_open recovery" do
    test "recovers after cooldown to half_open" do
      CircuitBreaker.record_failure("cooldown_test")
      CircuitBreaker.record_failure("cooldown_test")
      CircuitBreaker.record_failure("cooldown_test")
      assert CircuitBreaker.get_state("cooldown_test") == :open

      # Simulate cooldown expiry by inserting record with old timestamp
      old_ts = System.monotonic_time(:millisecond) - 400_000
      :ets.insert(:agent_ex_circuit_breaker, {"cooldown_test", :open, 3, old_ts})
      assert CircuitBreaker.get_state("cooldown_test") == :half_open
    end

    test "failure in half_open reopens circuit" do
      # Get to half_open
      CircuitBreaker.record_failure("halfopen_fail")
      CircuitBreaker.record_failure("halfopen_fail")
      CircuitBreaker.record_failure("halfopen_fail")
      old_ts = System.monotonic_time(:millisecond) - 400_000
      :ets.insert(:agent_ex_circuit_breaker, {"halfopen_fail", :open, 3, old_ts})
      assert CircuitBreaker.get_state("halfopen_fail") == :half_open

      # Fail during half_open
      CircuitBreaker.record_failure("halfopen_fail")
      assert CircuitBreaker.get_state("halfopen_fail") == :open
    end
  end

  describe "reset/1" do
    test "clears state for a specific tool" do
      CircuitBreaker.record_failure("tool_x")
      CircuitBreaker.record_failure("tool_x")
      CircuitBreaker.record_failure("tool_x")
      assert CircuitBreaker.get_state("tool_x") == :open

      CircuitBreaker.reset("tool_x")
      assert CircuitBreaker.get_state("tool_x") == :closed
    end
  end

  describe "reset_all/0" do
    test "clears all state" do
      CircuitBreaker.record_failure("a")
      CircuitBreaker.record_failure("a")
      CircuitBreaker.record_failure("a")
      CircuitBreaker.record_failure("b")

      CircuitBreaker.reset_all()
      assert CircuitBreaker.get_state("a") == :closed
      assert CircuitBreaker.get_state("b") == :closed
    end
  end
end
