defmodule AgentEx.Protocol do
  @moduledoc """
  Defines transport types for agent communication.

  ## Transport Types

  - `:llm` - Stateless LLM API calls (OpenAI, Anthropic, etc.)
  - `:local_agent` - Stateful CLI-based local agents (Claude Code, OpenCode)
  """

  @type transport_type :: :llm | :local_agent

  @doc "Returns a human-readable name for the transport type"
  def transport_type_name(:llm), do: "LLM API"
  def transport_type_name(:local_agent), do: "Local Agent"

  @doc "Returns whether the transport type is session-based"
  def session_based?(:llm), do: false
  def session_based?(:local_agent), do: true
end

defmodule AgentEx.Protocol.Error do
  @moduledoc "Protocol-specific errors"

  defmodule NotFound do
    @moduledoc "Raised when a requested protocol is not registered."
    defexception [:protocol_name]

    @impl true
    def message(%{protocol_name: protocol_name}),
      do: "Protocol '#{protocol_name}' not registered"
  end

  defmodule Unavailable do
    @moduledoc "Raised when a CLI-based protocol binary is not found or not executable."
    defexception [:cli_name, :reason]

    @impl true
    def message(%{cli_name: name, reason: reason}) do
      "CLI '#{name}' not available: #{reason}"
    end
  end

  defmodule SessionError do
    @moduledoc "Raised when a protocol session encounters an error."
    defexception [:session_id, :reason]

    @impl true
    def message(%{session_id: sid, reason: reason}) do
      "Session '#{sid}' error: #{reason}"
    end
  end
end
