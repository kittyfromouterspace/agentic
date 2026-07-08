defmodule Agentic.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Agentic.Memory.ContextKeeperRegistry},
      {Registry, keys: :unique, name: Agentic.Subagent.Registry},
      Agentic.Subagent.CoordinatorSupervisor,
      Agentic.LLM.ProviderRegistry,
      Agentic.LLM.Canonical,
      Agentic.LLM.Catalog,
      Agentic.LLM.SpendTracker,
      Agentic.LLM.UsageManager,
      Agentic.LLM.Timeout,
      Agentic.ModelRouter,
      Agentic.Protocol.Registry,
      Agentic.Strategy.Registry,
      Agentic.Telemetry.Aggregator
    ]

    opts = [strategy: :one_for_one, name: Agentic.Supervisor]

    # Initialize ETS tables
    Agentic.CircuitBreaker.init()
    Agentic.LLM.Credentials.init_store()

    # Register built-in protocols
    register_protocols()

    Supervisor.start_link(children, opts)
  end

  defp register_protocols do
    Agentic.Protocol.Registry.register(:llm, Agentic.Protocol.LLM)

    if Agentic.Protocol.ClaudeCode.available?() do
      Agentic.Protocol.Registry.register(:claude_code, Agentic.Protocol.ClaudeCode)
    end

    if Agentic.Protocol.OpenCode.available?() do
      Agentic.Protocol.Registry.register(:opencode, Agentic.Protocol.OpenCode)
    end

    if Agentic.Protocol.Codex.available?() do
      Agentic.Protocol.Registry.register(:codex, Agentic.Protocol.Codex)
    end

    Agentic.Protocol.Registry.register({:acp, :generic}, Agentic.Protocol.ACP)

    register_acp_agents()
  end

  defp register_acp_agents do
    agents = Application.get_env(:agentic, :acp_agents, [])

    Enum.each(agents, fn agent ->
      command = agent[:command] || agent["command"]
      name = agent[:name] || agent["name"]

      if command && name do
        if System.find_executable(command) do
          Agentic.Protocol.Registry.register({:acp, name}, Agentic.Protocol.ACP)
        end
      end
    end)
  end
end
