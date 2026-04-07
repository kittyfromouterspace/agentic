defmodule AgentEx.Subagent.DelegateTask do
  @moduledoc """
  Tool definition for delegating tasks to subagents.

  The `delegate_task` tool allows the main agent to spawn a bounded subagent
  that runs `AgentEx.run/1` with a separate context. The subagent inherits
  the workspace and callbacks but runs with reduced `max_turns` and an
  incremented `subagent_depth`.

  Subagents are synchronous in V2.0 — the main agent blocks until the
  subagent completes.
  """

  alias AgentEx.Subagent.Coordinator

  @max_subagent_depth 3
  @default_max_turns 20

  @doc "Returns the tool definition map."
  def definition do
    %{
      "name" => "delegate_task",
      "description" =>
        "Delegate a task to a subagent. The subagent runs autonomously with its own " <>
          "context and tool access. Use for parallelizable tasks like searching code, " <>
          "running tests, or investigating files while keeping the main context focused.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "Description of the task for the subagent to execute"
          },
          "max_turns" => %{
            "type" => "integer",
            "description" =>
              "Maximum turns for the subagent (default #{@default_max_turns}, max 50)"
          }
        },
        "required" => ["task"]
      }
    }
  end

  @doc "Execute the delegate_task tool."
  def execute(input, ctx) do
    task_prompt = input["task"]
    max_turns = min(input["max_turns"] || @default_max_turns, 50)

    cond do
      ctx.subagent_depth >= @max_subagent_depth ->
        {:error,
         "Cannot delegate: maximum subagent nesting depth (#{@max_subagent_depth}) reached"}

      task_prompt == nil or task_prompt == "" ->
        {:error, "Task description is required"}

      true ->
        workspace = ctx.metadata[:workspace]

        if workspace == nil do
          {:error, "No workspace configured"}
        else
          sub_callbacks =
            ctx.callbacks
            |> Map.drop([:on_human_input])

          opts = [
            parent_session_id: ctx.session_id,
            subagent_depth: ctx.subagent_depth,
            max_turns: max_turns,
            callbacks: sub_callbacks
          ]

          case Coordinator.spawn_subagent(workspace, task_prompt, opts) do
            {:ok, result} ->
              summary = format_result(result)
              {:ok, summary}

            {:error, :max_concurrent_reached} ->
              {:error,
               "Maximum concurrent subagents reached. Wait for current subagents to finish."}

            {:error, reason} ->
              {:error, "Subagent failed: #{inspect(reason)}"}
          end
        end
    end
  end

  defp format_result(%{text: text, cost: cost, steps: steps}) do
    "Subagent completed in #{steps} steps (cost: $#{Float.round(cost, 4)}).\n\n#{text}"
  end

  defp format_result(result) when is_binary(result) do
    result
  end

  defp format_result(result) do
    inspect(result)
  end
end
