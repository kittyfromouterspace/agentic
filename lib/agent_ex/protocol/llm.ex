defmodule AgentEx.Protocol.LLM do
  @moduledoc """
  LLM protocol implementation that wraps existing callback-based LLM calls.

  This protocol uses the existing `llm_chat` callback pattern, making it
  compatible with existing AgentEx integrations. It provides the same
  interface as other protocols but delegates to the callbacks.
  """

  use AgentEx.AgentProtocol

  alias AgentEx.Loop.Context

  @impl true
  def transport_type, do: :llm

  @impl true
  def start(_backend_config, %Context{} = _ctx) do
    # Stateless protocol - no session to start
    {:ok, "stateless"}
  end

  @impl true
  def send(_session_id, messages, %Context{} = ctx) do
    # Delegate to the llm_chat callback
    llm_chat = ctx.callbacks[:llm_chat]

    if llm_chat do
      llm_chat.(messages)
    else
      {:error, :no_llm_chat_callback}
    end
  end

  @impl true
  def resume(session_id, messages, %Context{} = ctx) do
    # For stateless protocols, resume is same as send
    send(session_id, messages, ctx)
  end

  @impl true
  def stop(_session_id) do
    # Stateless - nothing to stop
    :ok
  end

  @impl true
  def parse_stream(chunk) do
    # For non-streaming LLM calls, just return the chunk as a message
    case Jason.decode(chunk) do
      {:ok, data} -> {:message, data}
      _ -> :partial
    end
  end

  @impl true
  def format_messages(messages, _ctx) do
    # Messages are already in the correct format for LLM APIs
    messages
  end

  @impl true
  def available? do
    true
  end
end
