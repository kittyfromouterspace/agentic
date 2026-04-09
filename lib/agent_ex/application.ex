defmodule AgentEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AgentEx.Memory.ContextKeeperRegistry},
      {Registry, keys: :unique, name: AgentEx.Subagent.Registry},
      AgentEx.Subagent.CoordinatorSupervisor,
      AgentEx.LLM.ProviderRegistry,
      AgentEx.LLM.Catalog,
      AgentEx.LLM.UsageManager,
      AgentEx.ModelRouter,
      AgentEx.Protocol.Registry
    ]

    opts = [strategy: :one_for_one, name: AgentEx.Supervisor]

    # Initialize ETS tables
    AgentEx.CircuitBreaker.init()

    # Register built-in protocols
    register_protocols()

    Supervisor.start_link(children, opts)
  end

  defp register_protocols do
    # Register LLM protocol (wrapper around existing callbacks)
    AgentEx.Protocol.Registry.register(:llm, AgentEx.Protocol.LLM)

    # Register CLI protocols (if available)
    if AgentEx.Protocol.ClaudeCode.available?() do
      AgentEx.Protocol.Registry.register(:claude_code, AgentEx.Protocol.ClaudeCode)
    end

    if AgentEx.Protocol.OpenCode.available?() do
      AgentEx.Protocol.Registry.register(:opencode, AgentEx.Protocol.OpenCode)
    end

    if AgentEx.Protocol.Codex.available?() do
      AgentEx.Protocol.Registry.register(:codex, AgentEx.Protocol.Codex)
    end
  end
end
