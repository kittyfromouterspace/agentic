defmodule AgentEx.Loop.Stages.CommitmentGate do
  @moduledoc """
  Intercepts unfulfilled commitments in agent responses.

  When the LLM returns `end_turn` with text like "Let me analyze..." but hasn't
  used any tools, this stage catches it before the response reaches the user.
  It broadcasts the commitment text as a "thinking" indicator and re-enters the
  pipeline with a nudge to follow through.

  Placed after ToolExecutor in the pipeline -- only fires on the end_turn path
  (no pending tool calls).
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context
  alias AgentEx.Loop.Helpers
  alias AgentEx.Memory.CommitmentDetector
  alias AgentEx.Telemetry

  require Logger

  @max_continuations 2

  @impl true
  def call(%Context{} = ctx, next) do
    if ctx.pending_tool_calls == [] and ctx.commitment_continuations < @max_continuations and
         has_commitment?(ctx) do
      handle_commitment(ctx)
    else
      next.(ctx)
    end
  end

  defp has_commitment?(ctx) do
    text = ctx.accumulated_text
    text != "" and CommitmentDetector.commitment_detected?(text)
  end

  defp handle_commitment(ctx) do
    commitment = CommitmentDetector.extract_commitment(ctx.accumulated_text)
    workspace_id = ctx.metadata[:workspace_id]

    Logger.info(
      "CommitmentGate: intercepted unfulfilled commitment in #{ctx.session_id}: #{inspect(commitment)}"
    )

    Telemetry.event(
      [:commitment, :detected],
      %{continuations: ctx.commitment_continuations + 1},
      %{
        session_id: ctx.session_id
      }
    )

    Context.emit_event(ctx, {:commitment_continuation, ctx.accumulated_text, workspace_id})

    response = ctx.last_response || %AgentEx.LLM.Response{}
    content = response.content

    assistant_msg = %{"role" => "assistant", "content" => content}

    nudge = %{
      "role" => "user",
      "content" =>
        "[System: You said \"#{commitment || "you would take action"}\" but didn't use any tools. " <>
          "Follow through on your stated action now. Do not explain what you plan to do -- just do it.]"
    }

    ctx = %{
      ctx
      | accumulated_text: "",
        messages: ctx.messages ++ [assistant_msg, nudge],
        commitment_continuations: ctx.commitment_continuations + 1
    }

    if ctx.reentry_pipeline do
      ctx.reentry_pipeline.(ctx)
    else
      Logger.warning("CommitmentGate: no reentry pipeline available, falling through")
      {:done, Helpers.result_from_context(ctx)}
    end
  end
end
