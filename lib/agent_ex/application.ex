defmodule AgentEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AgentEx.Memory.ContextKeeperRegistry},
      {Registry, keys: :unique, name: AgentEx.Subagent.Registry},
      AgentEx.Subagent.CoordinatorSupervisor,
      AgentEx.ModelRouter,
      AgentEx.ModelRouter.Free
    ]

    opts = [strategy: :one_for_one, name: AgentEx.Supervisor]

    # Initialize ETS tables
    AgentEx.CircuitBreaker.init()

    Supervisor.start_link(children, opts)
  end
end
