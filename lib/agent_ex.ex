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
  alias AgentEx.Tools
  alias AgentEx.Tools.Activation

  require Logger

  @doc """
  Run the agent loop.

  ## Options

  - `:prompt` — user prompt (required)
  - `:workspace` — workspace directory path (required)
  - `:callbacks` — map of callback functions (required, at minimum `:llm_chat`)
  - `:system_prompt` — custom system prompt (optional, auto-assembled if omitted)
  - `:history` — list of prior conversation messages (optional)
  - `:profile` — loop profile `:agentic` or `:conversational` (optional, default `:agentic`)
  - `:model_tier` — model tier for LLM calls (optional, default `:primary`)
  - `:session_id` — for telemetry and event tracking (optional)
  - `:user_id` — for API key resolution (optional)
  - `:caller` — pid to receive events (optional, defaults to self())
  - `:workspace_id` — workspace identifier for ContextKeeper (optional)
  - `:cost_limit` — per-session cost limit in USD (optional, default 5.0)

  Returns `{:ok, %{text: string, cost: float, tokens: integer, steps: integer}}` or `{:error, reason}`.
  """
  def run(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    workspace = Keyword.fetch!(opts, :workspace)
    callbacks = Keyword.fetch!(opts, :callbacks)
    history = Keyword.get(opts, :history, [])
    profile_name = Keyword.get(opts, :profile, :agentic)
    model_tier = Keyword.get(opts, :model_tier, :primary)
    session_id = Keyword.get(opts, :session_id, generate_session_id())
    user_id = Keyword.get(opts, :user_id)
    caller = Keyword.get(opts, :caller, self())
    workspace_id = Keyword.get(opts, :workspace_id)
    cost_limit = Keyword.get(opts, :cost_limit, 5.0)

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        "You are a helpful AI assistant working in #{workspace}."
      end)

    messages =
      [%{"role" => "system", "content" => system_prompt}] ++
        history ++
        [%{"role" => "user", "content" => prompt}]

    # Merge default tool handler into callbacks if not provided
    callbacks =
      Map.put_new(callbacks, :execute_tool, fn name, input, ctx ->
        Tools.execute(name, input, ctx)
      end)

    core_tools = Tools.definitions()

    config = Profile.config(profile_name)
    config = Map.put(config, :session_cost_limit_usd, cost_limit)

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
        config: config,
        callbacks: callbacks
      )

    ctx = Activation.init(ctx)

    stages = Profile.stages(profile_name)
    pipeline = Engine.build_pipeline(stages)
    ctx = %{ctx | reentry_pipeline: pipeline}

    Engine.run(ctx, stages)
  end

  @doc "Scaffold a new workspace directory with default identity files."
  def new_workspace(path, opts \\ []) do
    AgentEx.Workspace.Service.create_workspace(path, opts)
  end

  defp generate_session_id do
    "agx-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
