defmodule AgentEx.Loop.ProfileTest do
  use ExUnit.Case, async: true

  alias AgentEx.Loop.Profile

  describe "stages/1" do
    test "agentic profile has 6 stages" do
      stages = Profile.stages(:agentic)
      assert length(stages) == 6

      assert AgentEx.Loop.Stages.ContextGuard in stages
      assert AgentEx.Loop.Stages.ProgressInjector in stages
      assert AgentEx.Loop.Stages.LLMCall in stages
      assert AgentEx.Loop.Stages.StopReasonRouter in stages
      assert AgentEx.Loop.Stages.ToolExecutor in stages
      assert AgentEx.Loop.Stages.CommitmentGate in stages
    end

    test "conversational profile has 3 stages" do
      stages = Profile.stages(:conversational)
      assert length(stages) == 3

      assert AgentEx.Loop.Stages.ContextGuard in stages
      assert AgentEx.Loop.Stages.LLMCall in stages
      assert AgentEx.Loop.Stages.StopReasonRouter in stages
    end

    test "unknown profile falls back to agentic" do
      assert Profile.stages(:unknown) == Profile.stages(:agentic)
    end
  end

  describe "config/1" do
    test "agentic config returns valid defaults" do
      config = Profile.config(:agentic)
      assert config.max_turns == 50
      assert config.compaction_at_pct == 0.80
      assert config.plan_required == false
      assert config.verify_on_complete == false
      assert config.progress_injection == :system_reminder
      assert config.telemetry_prefix == [:agent_ex]
    end

    test "conversational config returns valid defaults" do
      config = Profile.config(:conversational)
      assert config.max_turns == 100
      assert config.progress_injection == :none
    end
  end

  describe "resolve_from_capabilities/1" do
    test "selects agentic for tool_use" do
      assert Profile.resolve_from_capabilities([:tool_use]) == :agentic
    end

    test "selects agentic for image_gen" do
      assert Profile.resolve_from_capabilities([:image_gen]) == :agentic
    end

    test "selects conversational when no tool_use" do
      assert Profile.resolve_from_capabilities([:text_only]) == :conversational
    end

    test "selects agentic for non-list input" do
      assert Profile.resolve_from_capabilities(nil) == :agentic
    end
  end
end
