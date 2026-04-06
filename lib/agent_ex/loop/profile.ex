defmodule AgentEx.Loop.Profile do
  @moduledoc """
  Defines loop profiles -- named compositions of stages and config.

  Each profile is a set of stages that compose to form a specific agent behavior.
  Adding a new agent "mode" is just defining a new profile.

  ## Profiles

  - `:agentic` -- Full pipeline with tool use, progress tracking, context management
  - `:conversational` -- Simple call-respond loop, no tool execution
  """

  alias AgentEx.Loop.Stages

  @doc "Returns the stage list for the given profile."
  def stages(:agentic) do
    [
      Stages.ContextGuard,
      Stages.ProgressInjector,
      Stages.LLMCall,
      Stages.StopReasonRouter,
      Stages.ToolExecutor,
      Stages.CommitmentGate
    ]
  end

  def stages(:conversational) do
    [
      Stages.ContextGuard,
      Stages.LLMCall,
      Stages.StopReasonRouter
    ]
  end

  def stages(_), do: stages(:agentic)

  @doc "Returns the default config for the given profile."
  def config(:agentic) do
    %{
      max_turns: 50,
      compaction_at_pct: 0.80,
      plan_required: false,
      verify_on_complete: false,
      progress_injection: :system_reminder,
      telemetry_prefix: [:agent_ex]
    }
  end

  def config(:conversational) do
    %{
      max_turns: 100,
      compaction_at_pct: 0.80,
      plan_required: false,
      verify_on_complete: false,
      progress_injection: :none,
      telemetry_prefix: [:agent_ex]
    }
  end

  def config(_), do: config(:agentic)

  @doc """
  Resolve which profile to use based on model capabilities.

  If the model supports tool_use, use the agentic profile.
  Otherwise, use conversational.
  """
  def resolve_from_capabilities(capabilities) when is_list(capabilities) do
    cond do
      :tool_use in capabilities -> :agentic
      :image_gen in capabilities -> :agentic
      true -> :conversational
    end
  end

  def resolve_from_capabilities(_), do: :agentic
end
