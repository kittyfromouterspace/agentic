defmodule AgentEx do
  @moduledoc """
  AgentEx — A composable AI agent runtime for Elixir.

  Provides a complete agent loop with skills, working memory, knowledge
  persistence, and tool use. Drop it into any Elixir project to get a
  fully functional AI agent.

  ## Quick Start

      AgentEx.run(
        prompt: "Help me refactor this module",
        workspace: "/path/to/workspace",
        callbacks: %{
          llm_chat: fn params -> MyLLM.chat(params) end
        }
      )

  ## Callbacks

  The `callbacks` map connects AgentEx to your LLM provider and external systems:

  ### Required
  - `:llm_chat` - `(params) -> {:ok, response} | {:error, term}`

  ### Optional
  - `:execute_tool` - custom tool handler (defaults to AgentEx.Tools)
  - `:on_event` - `(event, ctx) -> :ok` for UI streaming
  - `:on_response_facts` - `(ctx, text) -> :ok` for custom fact processing
  - `:on_tool_facts` - `(ws_id, name, result, turn) -> :ok`
  - `:on_persist_turn` - `(ctx, text) -> :ok`
  - `:get_tool_schema` - `(name) -> {:ok, schema} | {:error, reason}`
  - `:get_secret` - `(service, key) -> {:ok, value} | {:error, reason}`
  - `:knowledge_search` - `(query, opts) -> {:ok, entries} | {:error, term}`
  - `:knowledge_create` - `(params) -> {:ok, entry} | {:error, term}`
  - `:knowledge_recent` - `(scope_id) -> {:ok, entries} | {:error, term}`
  - `:search_tools` - `(query, opts) -> [result]`
  - `:execute_external_tool` - `(name, args, ctx) -> {:ok, result} | {:error, reason}`
  """

  alias AgentEx.Loop.Context
  alias AgentEx.Loop.Engine
  alias AgentEx.Loop.Profile
  alias AgentEx.ModelRouter
  alias AgentEx.Tools
  alias AgentEx.Tools.Activation
  alias AgentEx.Telemetry

  require Logger

  @doc """
  Run the agent loop.

  ## Options

  - `:prompt` — user prompt (required)
  - `:workspace` — workspace directory path (required)
  - `:callbacks` — map of callback functions (required, at minimum `:llm_chat`)
  - `:system_prompt` — custom system prompt (optional, auto-assembled if omitted)
  - `:history` — list of prior conversation messages (optional)
  - `:profile` — loop profile (optional, default `:agentic`)
  - `:mode` — execution mode `:agentic | :agentic_planned | :turn_by_turn | :conversational` (optional, overrides `:profile`)
  - `:plan` — pre-built plan map for `:agentic_planned` mode, skips planning phase (optional)
  - `:model_tier` — model tier for LLM calls (optional, default `:primary`)
  - `:model_selection_mode` — `:manual` or `:auto` (optional, default `:manual`)
  - `:model_preference` — `:optimize_price` or `:optimize_speed` (optional, default `:optimize_price`, only used in `:auto` mode)
  - `:model_filter` — constrain model candidates: `:free_only` or `nil` (optional, only used in `:auto` mode)
  - `:session_id` — for telemetry and event tracking (optional)
  - `:user_id` — for API key resolution (optional)
  - `:caller` — pid to receive events (optional, defaults to self())
  - `:workspace_id` — workspace identifier for ContextKeeper (optional)
  - `:cost_limit` — per-session cost limit in USD (optional, default 5.0)
  - `:model_routes` — fallback model routes for routing (optional, e.g. `[primary: [...]]`)

  Returns `{:ok, %{text: string, cost: float, tokens: integer, steps: integer}}` or `{:error, reason}`.
  """
  def run(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    workspace = Keyword.fetch!(opts, :workspace)
    callbacks = Keyword.fetch!(opts, :callbacks)
    history = Keyword.get(opts, :history, [])
    mode = Keyword.get(opts, :mode, :agentic)
    profile_name = Keyword.get_lazy(opts, :profile, fn -> mode end)
    model_tier = Keyword.get(opts, :model_tier, :primary)
    model_selection_mode = Keyword.get(opts, :model_selection_mode, :manual)
    model_preference = Keyword.get(opts, :model_preference, :optimize_price)
    model_filter = Keyword.get(opts, :model_filter)
    strategy = Keyword.get(opts, :strategy, :default)
    session_id = Keyword.get(opts, :session_id, generate_session_id())
    user_id = Keyword.get(opts, :user_id)
    caller = Keyword.get(opts, :caller, self())
    workspace_id = Keyword.get(opts, :workspace_id)
    cost_limit = Keyword.get(opts, :cost_limit, 5.0)
    prebuilt_plan = Keyword.get(opts, :plan)
    tool_permissions = Keyword.get(opts, :tool_permissions, %{})

    if model_routes = opts[:model_routes] do
      Enum.each(model_routes, fn {tier, routes} ->
        ModelRouter.set_routes(tier, routes)
      end)
    else
      if tier_overrides = opts[:tier_overrides] do
        ModelRouter.set_tier_overrides(tier_overrides)
      end
    end

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        "You are a helpful AI assistant working in #{workspace}."
      end)

    messages =
      [%{"role" => "system", "content" => system_prompt}] ++
        history ++
        [%{"role" => "user", "content" => prompt}]

    callbacks =
      Map.put_new(callbacks, :execute_tool, fn name, input, ctx ->
        Tools.execute(name, input, ctx)
      end)

    callbacks =
      if backend = opts[:transcript_backend] do
        Map.put_new(callbacks, :transcript_backend, backend)
      else
        callbacks
      end

    core_tools = Tools.definitions()

    config = Profile.config(profile_name)
    config = Map.put(config, :session_cost_limit_usd, cost_limit)

    initial_phase = AgentEx.Loop.Phase.initial_phase(mode)

    effective_phase =
      if prebuilt_plan != nil and mode == :agentic_planned do
        :execute
      else
        initial_phase
      end

    ctx =
      Context.new(
        session_id: session_id,
        user_id: user_id,
        caller: caller,
        metadata: %{workspace: workspace, workspace_id: workspace_id},
        messages: messages,
        core_tools: core_tools,
        tools: core_tools,
        model_tier: model_tier,
        model_selection_mode: model_selection_mode,
        model_preference: model_preference,
        model_filter: model_filter,
        strategy: strategy,
        config: config,
        callbacks: callbacks
      )

    ctx = %{ctx | mode: mode, phase: effective_phase, tool_permissions: tool_permissions}

    ctx =
      if prebuilt_plan != nil do
        %{ctx | plan: prebuilt_plan}
      else
        ctx
      end

    ctx = Activation.init(ctx)

    stages = Profile.stages(profile_name)
    pipeline = Engine.build_pipeline(stages)
    ctx = %{ctx | reentry_pipeline: pipeline}

    Telemetry.event([:session, :start], %{}, %{
      session_id: session_id,
      mode: mode,
      profile: profile_name,
      strategy: strategy
    })

    session_start = System.monotonic_time()

    result = Engine.run(ctx, stages)

    session_duration = System.monotonic_time() - session_start

    case result do
      {:ok, res} ->
        Telemetry.event([:session, :stop], Map.put(res, :duration, session_duration), %{
          session_id: session_id,
          mode: mode,
          strategy: strategy
        })

      {:error, reason} ->
        Telemetry.event([:session, :error], %{duration: session_duration}, %{
          session_id: session_id,
          mode: mode,
          strategy: strategy,
          error: inspect(reason)
        })
    end

    result
  end

  @doc "Scaffold a new workspace directory with default identity files."
  def new_workspace(path, opts \\ []) do
    AgentEx.Workspace.Service.create_workspace(path, opts)
  end

  @doc """
  Resume a previous session from its transcript.

  Loads the transcript for the given session, reconstructs the conversation
  messages, and starts the pipeline from where it left off.

  ## Options

  - `:session_id` — session to resume (required)
  - `:workspace` — workspace directory path (required)
  - `:callbacks` — map of callback functions (required, at minimum `:llm_chat`)
  - `:transcript_backend` — module implementing `AgentEx.Persistence.Transcript` (optional, defaults to `Transcript.Local`)
  - All other options from `run/1` are supported and override transcript values.
  """
  def resume(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.fetch!(opts, :workspace)
    callbacks = Keyword.fetch!(opts, :callbacks)
    backend = Keyword.get(opts, :transcript_backend, AgentEx.Persistence.Transcript.Local)

    case backend.load(session_id, workspace: workspace) do
      {:ok, events} when events != [] ->
        {messages, turns_used, cost, tokens, plan} = reconstruct_from_events(events)

        Telemetry.event([:session, :resume], %{}, %{
          session_id: session_id,
          turns_restored: turns_used
        })

        mode = Keyword.get(opts, :mode, :agentic)
        profile_name = Keyword.get_lazy(opts, :profile, fn -> mode end)
        model_tier = Keyword.get(opts, :model_tier, :primary)
        model_selection_mode = Keyword.get(opts, :model_selection_mode, :manual)
        model_preference = Keyword.get(opts, :model_preference, :optimize_price)
        model_filter = Keyword.get(opts, :model_filter)
        user_id = Keyword.get(opts, :user_id)
        caller = Keyword.get(opts, :caller, self())
        workspace_id = Keyword.get(opts, :workspace_id)
        cost_limit = Keyword.get(opts, :cost_limit, 5.0)

        _system_prompt =
          Keyword.get_lazy(opts, :system_prompt, fn ->
            "You are a helpful AI assistant working in #{workspace}."
          end)

        resume_msg = %{
          "role" => "user",
          "content" =>
            "[System: This session was resumed from a previous conversation. " <>
              "Continue from where you left off.]"
        }

        messages = messages ++ [resume_msg]

        callbacks =
          Map.put_new(callbacks, :execute_tool, fn name, input, ctx ->
            Tools.execute(name, input, ctx)
          end)

        callbacks = Map.put_new(callbacks, :transcript_backend, backend)

        core_tools = Tools.definitions()
        config = Profile.config(profile_name)
        config = Map.put(config, :session_cost_limit_usd, cost_limit)

        initial_phase = AgentEx.Loop.Phase.initial_phase(mode)

        ctx =
          Context.new(
            session_id: session_id,
            user_id: user_id,
            caller: caller,
            metadata: %{workspace: workspace, workspace_id: workspace_id},
            messages: messages,
            core_tools: core_tools,
            tools: core_tools,
            model_tier: model_tier,
            model_selection_mode: model_selection_mode,
            model_preference: model_preference,
            model_filter: model_filter,
            config: config,
            callbacks: callbacks
          )

        ctx = %{
          ctx
          | mode: mode,
            phase: initial_phase,
            turns_used: turns_used,
            total_cost: cost,
            total_tokens: tokens,
            plan: plan
        }

        ctx = Activation.init(ctx)

        stages = Profile.stages(profile_name)
        pipeline = Engine.build_pipeline(stages)
        ctx = %{ctx | reentry_pipeline: pipeline}

        Engine.run(ctx, stages)

      {:ok, []} ->
        {:error, :empty_transcript}

      {:error, :not_found} ->
        {:error, :session_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconstruct_from_events(events) do
    {messages, turns, cost, tokens, plan} =
      Enum.reduce(events, {[], 0, 0.0, 0, nil}, fn event, {msgs, turns, cost, tokens, plan} ->
        case event["type"] do
          "llm_response" ->
            data = event["data"] || %{}
            usage = data["usage"] || %{}
            input_t = usage["input_tokens"] || 0
            output_t = usage["output_tokens"] || 0

            content =
              if preview = data["content_preview"] do
                [%{"type" => "text", "text" => preview}]
              else
                []
              end

            assistant_msg = %{"role" => "assistant", "content" => content}

            {msgs ++ [assistant_msg], max(turns, event["turn"] || 0),
             cost + (data["cost"] || 0.0), tokens + input_t + output_t, plan}

          "tool_call" ->
            data = event["data"] || %{}

            tool_call = %{
              "type" => "tool_use",
              "id" => data["id"],
              "name" => data["name"],
              "input" => data["input"] || %{}
            }

            last = List.last(msgs)

            msgs =
              if last && last["role"] == "assistant" && is_list(last["content"]) do
                updated_content = last["content"] ++ [tool_call]
                List.replace_at(msgs, length(msgs) - 1, %{last | "content" => updated_content})
              else
                msgs ++
                  [%{"role" => "assistant", "content" => [tool_call]}]
              end

            tool_result = %{
              "type" => "tool_result",
              "tool_use_id" => data["id"],
              "content" => "[result from previous session]"
            }

            result_msg = %{"role" => "user", "content" => [tool_result]}
            {msgs ++ [result_msg], turns, cost, tokens, plan}

          "plan_snapshot" ->
            plan = event["data"]["plan"]
            {msgs, turns, cost, tokens, plan}

          "phase_transition" ->
            {msgs, turns, cost, tokens, plan}

          _ ->
            {msgs, turns, cost, tokens, plan}
        end
      end)

    {messages, turns, cost, tokens, plan}
  end

  defp generate_session_id do
    "agx-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
