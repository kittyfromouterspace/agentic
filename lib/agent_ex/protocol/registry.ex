defmodule AgentEx.Protocol.Registry do
  @moduledoc """
  Registry for agent protocol implementations.

  Provides lookup and discovery of available protocols, supporting
  both LLM API protocols and local agent CLI protocols.

  ## Usage

      # Register a protocol
      AgentEx.Protocol.Registry.register(:claude_code, AgentEx.Protocol.ClaudeCode)

      # Look up a protocol
      {:ok, module} = AgentEx.Protocol.Registry.lookup(:claude_code)

      # List all protocols
      AgentEx.Protocol.Registry.list()

      # Get protocols by transport type
      AgentEx.Protocol.Registry.for_transport(:local_agent)
  """

  use GenServer

  @name __MODULE__

  @initial_state %{
    protocols: %{},
    by_transport: %{llm: [], local_agent: []}
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Register a protocol under a name.

  The protocol module must implement `AgentProtocol` behaviour.
  """
  def register(name, protocol_module) when is_atom(name) do
    GenServer.cast(@name, {:register, name, protocol_module})
  end

  @doc """
  Unregister a protocol by name.
  """
  def unregister(name) do
    GenServer.cast(@name, {:unregister, name})
  end

  @doc """
  Look up a protocol by name.

  Returns `{:ok, module}` or `:error`.
  """
  def lookup(name) do
    GenServer.call(@name, {:lookup, name})
  end

  @doc """
  Get a protocol, raising if not found.
  """
  def get!(name) do
    case lookup(name) do
      {:ok, module} -> module
      :error -> raise "Protocol '#{name}' not registered"
    end
  end

  @doc """
  List all registered protocol names.
  """
  def list do
    GenServer.call(@name, :list)
  end

  @doc """
  List all protocols for a given transport type.
  """
  def for_transport(type) when type in [:llm, :local_agent] do
    GenServer.call(@name, {:for_transport, type})
  end

  @doc """
  Check if a protocol is available (CLI present, credentials configured, etc.)
  """
  def available?(name) do
    case lookup(name) do
      {:ok, module} ->
        Code.ensure_loaded?(module) && module.available?()

      _ ->
        false
    end
  end

  # --- Server Implementation ---

  @impl true
  def init(_opts) do
    {:ok, @initial_state}
  end

  @impl true
  def handle_cast({:register, name, module}, state) do
    if not ensure_protocol?(module) do
      raise "Module #{inspect(module)} does not implement AgentEx.AgentProtocol"
    end

    transport_type = module.transport_type()

    by_transport =
      case Map.get(state.by_transport, transport_type, []) do
        list when is_list(list) ->
          if name in list do
            state.by_transport
          else
            Map.put(state.by_transport, transport_type, [name | list])
          end
      end

    state = %{
      state
      | protocols: Map.put(state.protocols, name, module),
        by_transport: by_transport
    }

    {:noreply, state}
  end

  @impl true
  def handle_cast({:unregister, name}, state) do
    {module, protocols} = Map.pop(state.protocols, name)

    by_transport =
      if module do
        transport_type = module.transport_type()
        current = Map.get(state.by_transport, transport_type, [])
        Map.put(state.by_transport, transport_type, List.delete(current, name))
      else
        state.by_transport
      end

    state = %{state | protocols: protocols, by_transport: by_transport}

    {:noreply, state}
  end

  @impl true
  def handle_call({:lookup, name}, _from, state) do
    {:reply, Map.fetch(state.protocols, name), state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.protocols), state}
  end

  @impl true
  def handle_call({:for_transport, type}, _from, state) do
    {:reply, Map.get(state.by_transport, type, []), state}
  end

  # --- Private ---

  defp ensure_protocol?(module) do
    module.module_info(:attributes)
    |> Enum.any?(fn
      {:behaviour, [AgentEx.AgentProtocol | _]} -> true
      _ -> false
    end)
  rescue
    _ -> false
  end
end
