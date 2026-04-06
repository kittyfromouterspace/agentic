defmodule AgentEx.Memory.FactExtractorTest do
  use ExUnit.Case, async: true

  alias AgentEx.Memory.FactExtractor

  describe "extract_from_tool_result/3" do
    test "extracts file paths from text" do
      result = "Found the file at /home/user/project/lib/main.ex and also src/app.ts"
      facts = FactExtractor.extract_from_tool_result("read_file", result, 1)

      path_facts = Enum.filter(facts, &(&1.relation == "mentioned"))
      assert length(path_facts) > 0

      paths = Enum.map(path_facts, & &1.entity)
      assert "/home/user/project/lib/main.ex" in paths
    end

    test "extracts error facts from tool results" do
      result = "Error: Could not compile module MyApp.Router"
      facts = FactExtractor.extract_from_tool_result("bash", result, 1)

      error_facts = Enum.filter(facts, &(&1.relation == "error"))
      assert length(error_facts) > 0

      # Also should have a produced_error top-level fact
      assert Enum.any?(facts, &(&1.relation == "produced_error"))
    end

    test "extracts success facts" do
      result = "Successfully created the file."
      facts = FactExtractor.extract_from_tool_result("write_file", result, 1)

      success_facts = Enum.filter(facts, &(&1.relation == "succeeded"))
      assert length(success_facts) == 1
      assert hd(success_facts).entity == "write_file"
      assert hd(success_facts).confidence == 0.8
    end

    test "returns empty list for non-binary result" do
      assert FactExtractor.extract_from_tool_result("bash", nil, 1) == []
      assert FactExtractor.extract_from_tool_result("bash", 42, 1) == []
    end
  end

  describe "extract_from_response/2" do
    test "extracts decisions from response" do
      text = "I'll refactor the module to use GenServer instead of Agent for better control."
      facts = FactExtractor.extract_from_response(text, 1)

      decision_facts = Enum.filter(facts, &(&1.relation == "decided"))
      assert length(decision_facts) > 0
      assert hd(decision_facts).entity == "agent"
    end

    test "extracts file paths from response" do
      text = "Looking at /etc/config.yml and lib/my_app.ex for the configuration."
      facts = FactExtractor.extract_from_response(text, 2)

      path_facts = Enum.filter(facts, &(&1.relation == "mentioned"))
      assert length(path_facts) > 0
    end

    test "returns empty list for nil" do
      assert FactExtractor.extract_from_response(nil, 1) == []
    end

    test "returns empty list for empty text" do
      assert FactExtractor.extract_from_response("", 1) == []
    end
  end

  describe "qualifies_for_llm_extraction?/3" do
    test "qualifies with 3+ tool calls" do
      assert FactExtractor.qualifies_for_llm_extraction?(
               ["read_file", "bash", "write_file"],
               "Some response",
               5
             )
    end

    test "qualifies with memory_write tool" do
      assert FactExtractor.qualifies_for_llm_extraction?(
               ["memory_write"],
               "Saved a note.",
               5
             )
    end

    test "qualifies with decision language" do
      assert FactExtractor.qualifies_for_llm_extraction?(
               ["read_file"],
               "I decided to use a different approach.",
               1
             )
    end

    test "does not qualify with few tools and no decision language on non-qualifying turn" do
      refute FactExtractor.qualifies_for_llm_extraction?(
               ["read_file"],
               "Here are the contents.",
               1
             )
    end
  end
end
