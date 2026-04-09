defmodule AgentEx.AgentProtocol do
  @moduledoc """
  Behaviour for agent communication protocols.

  Implement this for backends that communicate via different wire formats,
  session management, or execution models.

  ## Protocol vs Transport

  - **Protocol** - High-level agent communication (LLM API vs CLI subprocess)
  - **Transport** - Wire-level HTTP implementations (OpenAI, Anthropic, etc.)

  Protocols handle session lifecycle, response parsing, and tool execution
  delegation. Transports handle the actual HTTP request/response mechanics.

  ## Implementations

  Built-in protocols:
  - `AgentEx.Protocol.LLM` - Wraps existing callback-based LLM calls
  - `AgentEx.Protocol.ClaudeCode` - Claude Code CLI via subprocess
  - `AgentEx.Protocol.OpenCode` - OpenCode CLI via subprocess

  ## Callbacks

  Implement all required callbacks for lifecycle management and message handling.
  Optional callbacks provide streaming, cost estimation, and MCP integration.
  """

  alias AgentEx.Loop.Context
  alias AgentEx.Protocol

  @type session_id :: binary()
  @type protocol_response :: %{
          optional(:content) => String.t(),
          optional(:tool_calls) => [map()],
          optional(:usage) => %{input: non_neg_integer(), output: non_neg_integer()},
          optional(:stop_reason) => String.t() | nil,
          optional(:metadata) => map()
        }

  @type start_opts :: [
          {:workspace, String.t()}
          | {:user_id, String.t()}
          | {:session_id, String.t()}
          | {:cli_config, map()}
        ]

  @type send_opts :: [
          {:stream, boolean()}
          | {:timeout_ms, non_neg_integer()}
        ]

  # --- Lifecycle ---

  @doc """
  Start a new agent session.

  Called when a new session begins. For session-based protocols (local agents),
  this spawns the subprocess. For stateless protocols (LLM), this may be
  a no-op or initialize rate limiting.

  ## Parameters

    - `backend_config` - Protocol-specific configuration (API keys, CLI paths, etc.)
    - `context` - The AgentEx context with metadata, config, and callbacks

  ## Returns

    - `{:ok, session_id}` - Session started successfully
    - `{:error, reason}` - Failed to start session
  """
  @callback start(backend_config :: map(), context :: Context.t()) ::
              {:ok, session_id} | {:error, term()}

  @doc """
  Send messages and receive a response.

  The core protocol interaction. Takes conversation history and returns
  the agent's response with potential tool calls.

  ## Parameters

    - `session_id` - Session from `start/2`
    - `messages` - List of message maps with :role and :content keys
    - `context` - AgentEx context

  ## Returns

    - `{:ok, response}` - Successful response
    - `{:error, reason}` - Failed to get response
  """
  @callback send(session_id, messages :: [map()], context :: Context.t()) ::
              {:ok, protocol_response} | {:error, term()}

  @doc """
  Resume an existing session with new messages.

  For session-based protocols, continues a paused session. For stateless
  protocols, equivalent to `send/3`.

  ## Parameters

    - `session_id` - Existing session ID from prior start/resume
    - `messages` - New messages to append
    - `context` - AgentEx context

  ## Returns

    - `{:ok, session_id, response}` - Session continued, with response
    - `{:error, reason}` - Failed to resume
  """
  @callback resume(session_id, messages :: [map()], context :: Context.t()) ::
              {:ok, session_id, protocol_response} | {:error, term()}

  @doc """
  Stop and cleanup a session.

  Gracefully terminates the session, persisting any state needed for resume.

  ## Parameters

    - `session_id` - Session to stop

  ## Returns

    - `:ok` - Stopped successfully
    - `{:error, reason}` - Error during cleanup (non-fatal)
  """
  @callback stop(session_id) :: :ok | {:error, term()}

  # --- Protocol-specific ---

  @doc """
  Parse a streaming chunk into messages.

  Called during streaming to convert raw bytes to structured data.
  Different protocols have different streaming formats (JSON, JSONL, SSE, etc.)

  ## Parameters

    - `chunk` - Raw bytes received from the agent

  ## Returns

    - `{:message, map()}` - Complete message parsed from chunk
    - `:partial` - Incomplete data, need more
    - `:eof` - Stream completed
    - `{:error, reason}` - Parse error
  """
  @callback parse_stream(chunk :: binary()) ::
              {:message, map()} | :partial | :eof | {:error, term()}

  @doc """
  Format messages for the wire protocol.

  Converts AgentEx message format to protocol-specific format.

  ## Parameters

    - `messages` - List of AgentEx messages (%{"role" => ..., "content" => ...})
    - `context` - AgentEx context

  ## Returns

    - `iodata()` - Formatted message(s) ready for wire transmission
  """
  @callback format_messages(messages :: [map()], context :: Context.t()) ::
              iodata()

  @doc """
  Return the transport type.

  Identifies whether this is an LLM API or local agent protocol.
  """
  @callback transport_type() :: Protocol.transport_type()

  # --- Optional callbacks ---

  @doc """
  Estimate cost for a response.

  For subscription-based agents (hourly/daily limits), this estimates
  the cost in abstract units. For LLM protocols, uses token counts.

  Default: returns 0.0
  """
  @callback estimate_cost(response :: protocol_response()) :: float()
  def estimate_cost(_), do: 0.0

  @doc """
  Get current usage stats for a session.

  Returns usage information for the current billing period.
  Useful for displaying progress bars or limits in the UI.

  Default: returns nil (no tracking)
  """
  @callback get_usage(session_id) :: map() | nil
  def get_usage(_), do: nil

  @doc """
  Check if protocol is available on the system.

  For local agent protocols, checks if CLI binary exists.
  For LLM protocols, checks if API credentials are configured.

  Default: returns true
  """
  @callback available?() :: boolean()
  def available?, do: true

  @doc """
  Stream a message chunk to the client.

  Called during response streaming to push partial data.
  The callback should be invoked from context.callbacks[:on_stream_message].

  Default: no-op
  """
  @callback stream_message(session_id, chunk :: map(), context :: Context.t()) :: :ok
  def stream_message(_, _, _), do: :ok

  # --- Default implementations ---

  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      def estimate_cost(_), do: 0.0
      def get_usage(_), do: nil
      def available?, do: true
      def stream_message(_, _, _), do: :ok

      defoverridable estimate_cost: 1,
                     get_usage: 1,
                     available?: 0,
                     stream_message: 3
    end
  end
end
