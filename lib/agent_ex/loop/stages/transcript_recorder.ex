defmodule AgentEx.Loop.Stages.TranscriptRecorder do
  @moduledoc """
  Records session events to a transcript backend for session resumption.

  Sits after ModeRouter in the pipeline. Records LLM responses, tool calls,
  tool results, and phase transitions as JSONL events via the configured
  transcript backend.

  Requires `ctx.callbacks[:transcript_backend]` to be set. If not present,
  this stage is a no-op pass-through.
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context

  @impl true
  def call(%Context{} = ctx, next) do
    ctx = record_events(ctx)
    next.(ctx)
  end

  defp record_events(%Context{last_response: nil} = ctx), do: ctx

  defp record_events(%Context{} = ctx) do
    backend = ctx.callbacks[:transcript_backend]
    workspace = ctx.metadata[:workspace]
    session_id = ctx.session_id

    if backend && workspace && session_id do
      opts = [workspace: workspace]

      record_llm_response(backend, session_id, ctx, opts)
      record_tool_events(backend, session_id, ctx, opts)

      ctx
    else
      ctx
    end
  end

  defp record_llm_response(backend, session_id, ctx, opts) do
    response = ctx.last_response
    turn = ctx.turns_used

    event = %{
      type: "llm_response",
      turn: turn,
      data: %{
        stop_reason: response["stop_reason"],
        usage: response["usage"],
        cost: response["cost"],
        content_preview: text_preview(response["content"])
      }
    }

    backend.append(session_id, event, opts)
  end

  defp record_tool_events(backend, session_id, ctx, opts) do
    pending = ctx.pending_tool_calls
    turn = ctx.turns_used

    Enum.each(pending, fn call ->
      event = %{
        type: "tool_call",
        turn: turn,
        data: %{
          id: call["id"],
          name: call["name"],
          input: call["input"]
        }
      }

      backend.append(session_id, event, opts)
    end)
  end

  defp text_preview(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
    |> String.slice(0, 500)
  end

  defp text_preview(_), do: nil
end
