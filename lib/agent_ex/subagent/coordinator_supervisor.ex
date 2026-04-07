defmodule AgentEx.Subagent.CoordinatorSupervisor do
  @moduledoc """
  Dynamic supervisor for per-workspace Coordinators.

  Starts Coordinator processes lazily via `start_coordinator/1`.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a Coordinator for the given workspace."
  def start_coordinator(workspace) do
    spec = {AgentEx.Subagent.Coordinator, workspace: workspace}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end
end
