defmodule AgentEx.Loop.Stages.LLMCall do
  @moduledoc """
  Makes the LLM API call and stores the response in context.

  Uses the `llm_chat` callback from `ctx.callbacks` to make the actual API call.
  The response is stored in `ctx.last_response` for the next stage
  (typically StopReasonRouter) to process.
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.Loop.Context

  require Logger

  @impl true
  def model_tier, do: :primary

  @impl true
  def call(%Context{} = ctx, next) do
    tier = ctx.model_tier || :primary

    Logger.debug(
      "LLMCall: turn #{ctx.turns_used + 1}/#{ctx.config.max_turns} for #{ctx.session_id} (tier: #{tier})"
    )

    params = %{
      "messages" => ctx.messages,
      "tools" => ctx.tools,
      "session_id" => ctx.session_id,
      "user_id" => ctx.user_id,
      "model_tier" => to_string(tier)
    }

    llm_chat = ctx.callbacks[:llm_chat] || fn _ -> {:error, :no_llm_adapter} end
    start_time = System.monotonic_time()

    case llm_chat.(params) do
      {:ok, response} ->
        duration = System.monotonic_time() - start_time
        telemetry_prefix = ctx.config[:telemetry_prefix] || [:agent_ex]

        try do
          usage = response["usage"] || %{}

          :telemetry.execute(
            telemetry_prefix ++ [:llm_call, :stop],
            %{
              duration: duration,
              input_tokens: usage["input_tokens"] || 0,
              output_tokens: usage["output_tokens"] || 0,
              cost_usd: response["cost"] || 0.0
            },
            %{model_tier: tier, session_id: ctx.session_id}
          )
        rescue
          _ -> :ok
        end

        ctx = Context.track_usage(ctx, response)
        ctx = %{ctx | last_response: response, turns_used: ctx.turns_used + 1}

        next.(ctx)

      {:error, reason} ->
        Logger.error("LLMCall failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
