defmodule AgentEx.Loop.Profile do
  @moduledoc """
  Defines loop profiles -- named compositions of stages and config.

  Each profile is a set of stages that compose to form a specific agent behavior.
  Adding a new agent "mode" is just defining a new profile.

  ## Profiles

  - `:agentic` -- Full pipeline with tool use, progress tracking, context management
  - `:agentic_planned` -- Two-phase: plan then execute with tracking and verification
  - `:turn_by_turn` -- LLM proposes chunks, human approves/edits before execution
  - `:conversational` -- Simple call-respond loop, no tool execution

  ## Protocol Support

  Each profile can declare a protocol to use for agent communication:

  - `:llm` (default) -- Uses LLM API calls via `llm_chat` callback
  - `:claude_code` -- Uses Claude Code CLI via local agent protocol
  - `:opencode` -- Uses OpenCode CLI via local agent protocol
  """

  alias AgentEx.Loop.Stages

  @type protocol_name :: :llm | :claude_code | :opencode | atom()

  @doc "Returns the stage list for the given profile."
  def stages(:agentic) do
    [
      Stages.ContextGuard,
      Stages.ProgressInjector,
      Stages.LLMCall,
      Stages.ModeRouter,
      Stages.TranscriptRecorder,
      Stages.ToolExecutor,
      Stages.CommitmentGate
    ]
  end

  def stages(:agentic_planned) do
    [
      Stages.WorkspaceSnapshot,
      Stages.ContextGuard,
      Stages.PlanBuilder,
      Stages.ProgressInjector,
      Stages.LLMCall,
      Stages.ModeRouter,
      Stages.TranscriptRecorder,
      Stages.ToolExecutor,
      Stages.PlanTracker,
      Stages.CommitmentGate
    ]
  end

  def stages(:turn_by_turn) do
    [
      Stages.WorkspaceSnapshot,
      Stages.ContextGuard,
      Stages.LLMCall,
      Stages.ModeRouter,
      Stages.TranscriptRecorder,
      Stages.HumanCheckpoint,
      Stages.ToolExecutor,
      Stages.CommitmentGate
    ]
  end

  def stages(:conversational) do
    [
      Stages.ContextGuard,
      Stages.LLMCall,
      Stages.ModeRouter,
      Stages.TranscriptRecorder
    ]
  end

  # CLI-based profiles (local agent protocols)
  def stages(:claude_code) do
    [
      Stages.ContextGuard,
      Stages.ProgressInjector,
      Stages.CLIExecutor,
      Stages.ModeRouter,
      Stages.TranscriptRecorder,
      Stages.ToolExecutor,
      Stages.CommitmentGate
    ]
  end

  def stages(:opencode) do
    stages(:claude_code)
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
      telemetry_prefix: [:agent_ex],
      protocol: :llm,
      transport_type: :llm
    }
  end

  def config(:agentic_planned) do
    %{
      max_turns: 100,
      compaction_at_pct: 0.80,
      progress_injection: :system_reminder,
      require_plan_verification: true,
      max_plan_steps: 20,
      telemetry_prefix: [:agent_ex],
      protocol: :llm,
      transport_type: :llm
    }
  end

  def config(:turn_by_turn) do
    %{
      max_turns: 200,
      compaction_at_pct: 0.80,
      progress_injection: :none,
      max_chunks_per_session: 50,
      telemetry_prefix: [:agent_ex],
      protocol: :llm,
      transport_type: :llm
    }
  end

  def config(:conversational) do
    %{
      max_turns: 100,
      compaction_at_pct: 0.80,
      plan_required: false,
      verify_on_complete: false,
      progress_injection: :none,
      telemetry_prefix: [:agent_ex],
      protocol: :llm,
      transport_type: :llm
    }
  end

  # CLI-based profiles
  def config(:claude_code) do
    %{
      max_turns: 50,
      compaction_at_pct: 0.80,
      plan_required: false,
      verify_on_complete: false,
      progress_injection: :system_reminder,
      telemetry_prefix: [:agent_ex],
      protocol: :claude_code,
      transport_type: :local_agent,
      cli_config: %{
        command: "claude",
        args: [
          "-p",
          "--output-format",
          "stream-json",
          "--include-partial-messages",
          "--verbose",
          "--permission-mode",
          "bypassPermissions"
        ],
        session_mode: :always,
        session_id_fields: ["session_id"]
      },
      # Usage limits for subscription agents
      session_cost_limit_usd: 5.0,
      # 10 minutes
      session_duration_limit_ms: 600_000
    }
  end

  def config(:opencode) do
    %{
      max_turns: 50,
      compaction_at_pct: 0.80,
      plan_required: false,
      verify_on_complete: false,
      progress_injection: :system_reminder,
      telemetry_prefix: [:agent_ex],
      protocol: :opencode,
      transport_type: :local_agent,
      cli_config: %{
        command: "opencode",
        args: ["--mode", "agent"],
        session_mode: :always,
        session_id_fields: ["session_id"]
      },
      session_cost_limit_usd: 5.0,
      session_duration_limit_ms: 600_000
    }
  end

  def config(:codex) do
    %{
      max_turns: 50,
      compaction_at_pct: 0.80,
      plan_required: false,
      verify_on_complete: false,
      progress_injection: :system_reminder,
      telemetry_prefix: [:agent_ex],
      protocol: :codex,
      transport_type: :local_agent,
      cli_config: %{
        command: "codex",
        args: ["--json"],
        session_mode: :always,
        session_id_fields: ["session_id"]
      },
      session_cost_limit_usd: 10.0,
      session_duration_limit_ms: 600_000
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
