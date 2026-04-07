defmodule AgentEx.Subagent.Coordinator do
  @moduledoc """
  Per-workspace subagent coordinator.

  Manages bounded concurrent subagent execution. Each workspace gets at most
  one Coordinator process (started lazily via `CoordinatorSupervisor`).

  The Coordinator:
  - Limits concurrent subagents (default 5)
  - Monitors subagent processes for crash detection
  - Delivers results back to the caller via GenServer.reply
  - Auto-shuts down when idle
  """

  use GenServer

  @max_concurrent 5
  @idle_timeout_ms 30_000

  defstruct [
    :workspace,
    :subagents
  ]

  def start_link(opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    GenServer.start_link(__MODULE__, workspace, name: via(workspace))
  end

  defp via(workspace) do
    {:via, Registry, {AgentEx.Subagent.Registry, workspace}}
  end

  @doc "Ensure a coordinator exists for the given workspace."
  def ensure_started(workspace) do
    case Registry.lookup(AgentEx.Subagent.Registry, workspace) do
      [{pid, _}] -> {:ok, pid}
      [] -> AgentEx.Subagent.CoordinatorSupervisor.start_coordinator(workspace)
    end
  end

  @doc """
  Spawn a subagent task synchronously.

  Blocks until the subagent completes. Returns `{:ok, result}` or `{:error, reason}`.
  """
  def spawn_subagent(workspace, task_prompt, opts) do
    {:ok, coordinator} = ensure_started(workspace)
    GenServer.call(coordinator, {:spawn_subagent, task_prompt, opts}, :infinity)
  end

  @doc "List active subagents for a workspace."
  def list_subagents(workspace) do
    case Registry.lookup(AgentEx.Subagent.Registry, workspace) do
      [{pid, _}] -> GenServer.call(pid, :list_subagents)
      [] -> {:ok, []}
    end
  end

  @impl true
  def init(workspace) do
    Process.send_after(self(), :check_idle_shutdown, @idle_timeout_ms)

    {:ok,
     %__MODULE__{
       workspace: workspace,
       subagents: %{}
     }}
  end

  @impl true
  def handle_call({:spawn_subagent, task_prompt, opts}, from, state) do
    active_count = map_size(state.subagents)

    if active_count >= @max_concurrent do
      {:reply, {:error, :max_concurrent_reached}, state}
    else
      parent_session_id = Keyword.get(opts, :parent_session_id)
      parent_depth = Keyword.get(opts, :subagent_depth, 0)
      max_turns = Keyword.get(opts, :max_turns, 20)
      callbacks = Keyword.fetch!(opts, :callbacks)
      workspace = state.workspace

      sub_session_id =
        "sub-#{parent_session_id || "anon"}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

      task =
        Task.async(fn ->
          AgentEx.run(
            prompt: task_prompt,
            workspace: workspace,
            session_id: sub_session_id,
            mode: :agentic,
            max_turns: max_turns,
            callbacks: callbacks
          )
        end)

      ref = task.ref

      subagent_info = %{
        session_id: sub_session_id,
        ref: ref,
        from: from,
        parent_session_id: parent_session_id,
        depth: parent_depth + 1,
        started_at: System.monotonic_time()
      }

      state = %{state | subagents: Map.put(state.subagents, ref, subagent_info)}
      {:noreply, state}
    end
  end

  def handle_call(:list_subagents, _from, state) do
    active =
      state.subagents
      |> Enum.map(fn {_ref, info} ->
        %{
          session_id: info.session_id,
          depth: info.depth,
          parent_session_id: info.parent_session_id
        }
      end)

    {:reply, {:ok, active}, state}
  end

  @impl true
  def handle_info({ref, result}, state) do
    case Map.pop(state.subagents, ref) do
      {nil, _} ->
        {:noreply, state}

      {info, new_subagents} ->
        GenServer.reply(info.from, result)
        state = %{state | subagents: new_subagents}
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.subagents, ref) do
      {nil, _} ->
        {:noreply, state}

      {info, new_subagents} ->
        GenServer.reply(info.from, {:error, {:subagent_crashed, reason}})
        state = %{state | subagents: new_subagents}
        {:noreply, state}
    end
  end

  def handle_info(:check_idle_shutdown, state) do
    if map_size(state.subagents) == 0 do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :check_idle_shutdown, @idle_timeout_ms)
      {:noreply, state}
    end
  end

  def handle_info(_, state) do
    {:noreply, state}
  end
end
