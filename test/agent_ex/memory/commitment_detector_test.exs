defmodule AgentEx.Memory.CommitmentDetectorTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.CommitmentDetector

  describe "commitment_detected?/1" do
    test "detects 'let me check' patterns" do
      assert CommitmentDetector.commitment_detected?("Let me check the file.")
      assert CommitmentDetector.commitment_detected?("Let me look at the logs.")
      assert CommitmentDetector.commitment_detected?("Let me search for that function.")
      assert CommitmentDetector.commitment_detected?("Let me read the configuration.")
    end

    test "detects I'll patterns" do
      assert CommitmentDetector.commitment_detected?("I'll check the database.")
      assert CommitmentDetector.commitment_detected?("I'll investigate the issue.")
      assert CommitmentDetector.commitment_detected?("I'll find the relevant code.")
    end

    test "detects 'one moment' patterns" do
      assert CommitmentDetector.commitment_detected?("One moment, I'm working on this.")
      assert CommitmentDetector.commitment_detected?("Give me a moment to look at this.")
    end

    test "ignores 'let me know' (negative pattern)" do
      refute CommitmentDetector.commitment_detected?("Let me know if you need help.")
    end

    test "ignores 'feel free to' (negative pattern)" do
      refute CommitmentDetector.commitment_detected?("Feel free to ask questions.")
    end

    test "ignores 'would you like me to' (negative pattern)" do
      refute CommitmentDetector.commitment_detected?("Would you like me to check that?")
    end

    test "returns false for nil" do
      refute CommitmentDetector.commitment_detected?(nil)
    end

    test "returns false for empty string" do
      refute CommitmentDetector.commitment_detected?("")
    end

    test "returns false for plain text" do
      refute CommitmentDetector.commitment_detected?("The answer is 42.")
    end
  end

  describe "extract_commitment/1" do
    test "extracts commitment phrase" do
      result = CommitmentDetector.extract_commitment("Let me check the configuration now.")
      assert result != nil
      assert result =~ "Let me check"
    end

    test "extracts I'll phrase" do
      result = CommitmentDetector.extract_commitment("I'll investigate the error in the logs.")
      assert result != nil
      assert result =~ "I'll investigate"
    end

    test "returns nil for no commitment" do
      assert CommitmentDetector.extract_commitment("The sky is blue.") == nil
    end

    test "returns nil for nil input" do
      assert CommitmentDetector.extract_commitment(nil) == nil
    end

    test "returns nil for empty string" do
      assert CommitmentDetector.extract_commitment("") == nil
    end

    test "returns nil for negative patterns only" do
      assert CommitmentDetector.extract_commitment("Let me know if you need anything.") == nil
    end
  end
end
