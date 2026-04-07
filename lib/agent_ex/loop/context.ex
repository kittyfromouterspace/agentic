defmodule AgentEx.Loop.Context do
  @moduledoc """
  Shared state threaded through all loop stages.

  Contains everything a stage might need: messages, tools, identity info,
  resolved model, progress tracking, callbacks, and configuration.
  """

  defstruct [
    # Identity (default nil)
    session_id: nil,
    user_id: nil,
    caller: nil,

    # Arbitrary metadata (workspace_id, workspace path, etc.)
    metadata: %{},

    # Model (resolved per-stage by engine)
    resolved_model: nil,

    # Model tier resolved from skill requirements (:primary, :lightweight, :any)
    model_tier: :primary,

    # Conversation
    messages: [],
    tools: [],
    core_tools: [],

    # Mode and phase
    mode: :agentic,
    phase: :execute,

    # Progress tracking
    turns_used: 0,
    context_pct: 0.0,
    accumulated_text: "",

    # Plan tracking (agentic_planned mode)
    plan: nil,
    plan_step_index: 0,
    plan_steps_completed: [],

    # Human-in-the-loop (turn_by_turn mode)
    human_input: nil,
    pending_human_response: false,

    # Workspace context
    workspace_snapshot: nil,
    file_reads: %{},

    # Cache awareness (V1.2)
    stable_prefix_hash: nil,

    # Subagent support (V2.0)
    subagent_depth: 0,
    subagent_budget: nil,
    parent_session_id: nil,

    # Tool permissions (V2.1)
    tool_permissions: %{},

    # Cost tracking
    total_cost: 0.0,
    total_tokens: 0,

    # Activation state (from tool gateway)
    activation: %{},

    # Pipeline state (set by stages, threaded through loop iterations)
    last_response: nil,
    pending_tool_calls: [],
    reentry_pipeline: nil,
    summary_nudge_sent: false,
    commitment_continuations: 0,

    # Config
    config: %{
      max_turns: 50,
      compaction_at_pct: 0.80,
      plan_required: false,
      verify_on_complete: false,
      progress_injection: :none,
      telemetry_prefix: [:agent_ex]
    },

    # Callbacks (functions, not behaviours)
    # Required: :llm_chat, :execute_tool
    # Optional: :on_event, :on_response_facts, :on_tool_facts, :on_persist_turn,
    #           :get_tool_schema, :get_secret, :tool_definitions
    callbacks: %{}
  ]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          user_id: String.t() | nil,
          caller: pid() | nil,
          metadata: map(),
          resolved_model: map() | nil,
          messages: list(map()),
          tools: list(map()),
          core_tools: list(map()),
          mode: :agentic | :agentic_planned | :turn_by_turn | :conversational,
          phase: atom(),
          turns_used: non_neg_integer(),
          context_pct: float(),
          accumulated_text: String.t(),
          plan: map() | nil,
          plan_step_index: non_neg_integer(),
          plan_steps_completed: list(non_neg_integer()),
          human_input: String.t() | nil,
          pending_human_response: boolean(),
          workspace_snapshot: String.t() | nil,
          file_reads: %{String.t() => %{hash: String.t(), last_read_turn: non_neg_integer()}},
          stable_prefix_hash: String.t() | nil,
          subagent_depth: non_neg_integer(),
          subagent_budget: float() | nil,
          parent_session_id: String.t() | nil,
          tool_permissions: %{String.t() => :auto | :approve | :deny},
          total_cost: float(),
          total_tokens: non_neg_integer(),
          model_tier: atom(),
          activation: map(),
          last_response: map() | nil,
          pending_tool_calls: list(map()),
          reentry_pipeline: (t() -> term()) | nil,
          summary_nudge_sent: boolean(),
          commitment_continuations: non_neg_integer(),
          config: map(),
          callbacks: map()
        }

  @doc "Create a new context from keyword opts."
  def new(opts) do
    %__MODULE__{
      session_id: Keyword.get(opts, :session_id),
      user_id: Keyword.get(opts, :user_id),
      caller: Keyword.get(opts, :caller),
      metadata: Keyword.get(opts, :metadata, %{}),
      messages: Keyword.get(opts, :messages, []),
      mode: Keyword.get(opts, :mode, :agentic),
      phase: Keyword.get(opts, :phase, :execute),
      plan: Keyword.get(opts, :plan),
      core_tools: Keyword.get(opts, :core_tools, []),
      tools: Keyword.get(opts, :tools, []),
      model_tier: Keyword.get(opts, :model_tier, :primary),
      config: Keyword.get(opts, :config, %__MODULE__{}.config),
      callbacks: Keyword.get(opts, :callbacks, %{})
    }
  end

  @doc "Track cost and token usage from an LLM response."
  def track_usage(ctx, response) do
    cost = response["cost"] || 0.0
    usage = response["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{ctx | total_cost: ctx.total_cost + cost, total_tokens: ctx.total_tokens + input + output}
  end

  @doc "Emit an event to the caller and optional on_event callback."
  def emit_event(%__MODULE__{} = ctx, event) do
    if cb = ctx.callbacks[:on_event], do: cb.(event, ctx)
    if ctx.caller, do: send(ctx.caller, event)
    :ok
  end
end
