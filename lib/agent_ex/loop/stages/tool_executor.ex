defmodule AgentEx.Loop.Stages.ToolExecutor do
  @moduledoc """
  Executes pending tool calls and re-enters the loop.

  When `StopReasonRouter` detects a `tool_use` stop_reason, it stores the tool
  calls in `ctx.pending_tool_calls`. This stage executes them, appends tool
  results to messages, rebuilds the tool list, and re-invokes the full pipeline.

  ## Callbacks

  Required on `ctx.callbacks`:
  - `:execute_tool` - `(name, input, ctx) -> {:ok, out} | {:ok, out, ctx} | {:error, term}`

  Optional:
  - `:on_tool_facts` - `(workspace_id, tool_name, result, turn) -> :ok`
  """

  @behaviour AgentEx.Loop.Stage

  alias AgentEx.CircuitBreaker
  alias AgentEx.Loop.Context
  alias AgentEx.Tools.Activation

  require Logger

  @impl true
  def call(%Context{} = ctx, next) do
    if ctx.pending_tool_calls == [] do
      next.(ctx)
    else
      {tool_results, ctx} = execute_tool_calls(ctx.pending_tool_calls, ctx)
      tool_result_msg = build_tool_result_message(tool_results)

      tools = build_tool_list(ctx)

      ctx = %{
        ctx
        | messages: ctx.messages ++ [tool_result_msg],
          tools: tools,
          pending_tool_calls: []
      }

      if ctx.reentry_pipeline do
        ctx.reentry_pipeline.(ctx)
      else
        next.(ctx)
      end
    end
  end

  defp execute_tool_calls(tool_calls, ctx) do
    execute_tool =
      ctx.callbacks[:execute_tool] ||
        fn name, _input, ctx -> {:error, "No tool handler for #{name}", ctx} end

    Enum.map_reduce(tool_calls, ctx, fn call, ctx ->
      name = call["name"]
      workspace_id = ctx.metadata[:workspace_id]
      Context.emit_event(ctx, {:tool_use, name, workspace_id})
      input_summary = inspect(call["input"], limit: 200, printable_limit: 200)
      Logger.info("ToolExecutor: #{name} #{input_summary}")

      tool_start_time = System.monotonic_time()

      {result, is_error, ctx} =
        case CircuitBreaker.check(name) do
          {:error, :circuit_open} ->
            Logger.warning("CircuitBreaker: #{name} is open, skipping execution")

            {"Tool temporarily unavailable (repeated failures). Try a different approach or wait a few minutes.",
             true, ctx}

          :ok ->
            try do
              case execute_tool.(name, call["input"], ctx) do
                {:ok, output} ->
                  CircuitBreaker.record_success(name)
                  {output, false, ctx}

                {:ok, output, new_ctx} ->
                  CircuitBreaker.record_success(name)
                  {output, false, new_ctx}

                {:error, reason} when is_binary(reason) ->
                  CircuitBreaker.record_failure(name)
                  {reason, true, ctx}

                {:error, reason} ->
                  CircuitBreaker.record_failure(name)
                  {inspect(reason), true, ctx}
              end
            rescue
              e ->
                CircuitBreaker.record_failure(name)
                Logger.error("Tool #{name} crashed: #{Exception.message(e)}")
                {"Tool error: #{Exception.message(e)}", true, ctx}
            end
        end

      Context.emit_event(ctx, {:tool_use, nil, workspace_id})

      # Log result for debugging
      result_preview =
        if is_binary(result), do: String.slice(result, 0, 300), else: inspect(result, limit: 200)

      error_tag = if is_error, do: " [ERROR]", else: ""
      Logger.info("ToolExecutor: #{name} ->#{error_tag} #{result_preview}")

      # Broadcast trace event
      trace_output =
        if is_binary(result), do: String.slice(result, 0, 2000), else: inspect(result, limit: 500)

      Context.emit_event(
        ctx,
        {:tool_trace, name, call["input"], trace_output, is_error, workspace_id}
      )

      telemetry_prefix = ctx.config[:telemetry_prefix] || [:agent_ex]

      try do
        tool_duration = System.monotonic_time() - tool_start_time
        output_bytes = if is_binary(result), do: byte_size(result), else: 0

        :telemetry.execute(
          telemetry_prefix ++ [:tool, :stop],
          %{duration: tool_duration, output_bytes: output_bytes},
          %{tool_name: name, success: not is_error, session_id: ctx.session_id}
        )
      rescue
        _ -> :ok
      end

      # Run optional fact extraction callback
      if cb = ctx.callbacks[:on_tool_facts] do
        try do
          cb.(workspace_id, name, result, ctx.turns_used)
        rescue
          _ -> :ok
        end
      end

      {%{
         "tool_use_id" => call["id"],
         "content" => sanitize_tool_output(result),
         "is_error" => is_error
       }, ctx}
    end)
  end

  defp build_tool_result_message(results) do
    blocks =
      Enum.map(results, fn result ->
        base = %{
          "type" => "tool_result",
          "tool_use_id" => result["tool_use_id"],
          "content" => result["content"]
        }

        if result["is_error"], do: Map.put(base, "is_error", true), else: base
      end)

    %{"role" => "user", "content" => blocks}
  end

  defp build_tool_list(ctx) do
    activated = Activation.active_tool_definitions(ctx)
    ctx.core_tools ++ activated
  end

  defp sanitize_tool_output(output) when is_binary(output) do
    if String.valid?(output) do
      output
    else
      "[binary content, #{byte_size(output)} bytes -- not valid UTF-8]"
    end
  end

  defp sanitize_tool_output(output), do: output
end
