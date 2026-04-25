defmodule Agentic.Loop.Stages.WorkspaceSnapshot do
  @moduledoc """
  Gathers workspace context and injects it into the conversation.

  Only active on the first pipeline pass (`ctx.turns_used == 0`). Sits before
  ContextGuard in every pipeline that includes it.

  Responsibilities:
  - Gather workspace context: git branch/status/recent commits, file tree,
    instruction files, project config
  - Inject a structured workspace context message into `ctx.messages`
  - Check `ctx.callbacks[:on_workspace_snapshot]` — if provided, use the host's
    snapshot; otherwise gather automatically
  - On subsequent passes, no-ops (the snapshot is already in messages)
  """

  @behaviour Agentic.Loop.Stage

  alias Agentic.Loop.Context

  @instruction_files ~w(AGENTS.md README.md CLAUDE.md .cursorrules)
  @config_files ~w(mix.exs package.json Cargo.toml pyproject.toml go.mod)

  @impl true
  def call(%Context{turns_used: 0} = ctx, next) do
    if ctx.workspace_snapshot != nil do
      next.(ctx)
    else
      snapshot = gather_snapshot(ctx)
      ctx = %{ctx | workspace_snapshot: snapshot}
      ctx = inject_snapshot_message(ctx, snapshot)
      next.(ctx)
    end
  end

  @impl true
  def call(ctx, next), do: next.(ctx)

  defp gather_snapshot(ctx) do
    case ctx.callbacks[:on_workspace_snapshot] do
      cb when is_function(cb, 1) ->
        case cb.(workspace_path(ctx)) do
          {:ok, snapshot} -> snapshot
          {:error, _} -> auto_gather(ctx)
        end

      _ ->
        auto_gather(ctx)
    end
  end

  defp auto_gather(ctx) do
    workspace = workspace_path(ctx)

    parts = [
      gather_git_context(workspace),
      gather_file_tree(workspace),
      gather_instruction_files(workspace),
      gather_project_config(workspace)
    ]

    parts
    |> Enum.filter(&(&1 != ""))
    |> Enum.join("\n\n")
  end

  defp gather_git_context(workspace) do
    git_info =
      with {:ok, branch} <- run_git(workspace, "rev-parse --abbrev-ref HEAD"),
           {:ok, status} <- run_git(workspace, "status --short"),
           {:ok, log} <- run_git(workspace, "log --oneline -5") do
        status_line =
          if String.trim(status) == "" do
            "  Status: clean"
          else
            changed = status |> String.trim() |> String.split("\n") |> length()
            "  Status: #{changed} changed file(s)"
          end

        "## Git Context\n  Branch: #{String.trim(branch)}\n#{status_line}\n  Recent commits:\n#{indent_lines(String.trim(log), "    ")}"
      else
        _ -> ""
      end

    git_info
  end

  defp gather_file_tree(workspace) do
    case File.ls(workspace) do
      {:ok, entries} ->
        filtered =
          entries
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.sort()
          |> Enum.take(50)
          |> Enum.join("\n")

        if filtered != "" do
          "## File Tree (top-level)\n#{indent_lines(filtered, "  ")}"
        else
          ""
        end

      _ ->
        ""
    end
  end

  defp gather_instruction_files(workspace) do
    contents =
      @instruction_files
      |> Enum.map(fn name ->
        path = Path.join(workspace, name)

        case File.read(path) do
          {:ok, content} ->
            trimmed = String.slice(content, 0, 3000)

            if String.length(content) > 3000 do
              "## #{name}\n#{trimmed}\n[... truncated]"
            else
              "## #{name}\n#{trimmed}"
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if contents != [], do: Enum.join(contents, "\n\n"), else: ""
  end

  defp gather_project_config(workspace) do
    @config_files
    |> Enum.map(fn name ->
      path = Path.join(workspace, name)

      case File.read(path) do
        {:ok, content} ->
          "## #{name}\n#{String.slice(content, 0, 2000)}"

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp inject_snapshot_message(ctx, snapshot) when snapshot != "" do
    msg = %{
      "role" => "user",
      "content" => "[System: Workspace context]\n#{snapshot}\n[End workspace context]"
    }

    system_idx = find_system_prompt_index(ctx.messages)

    {before, after_} = Enum.split(ctx.messages, system_idx + 1)
    %{ctx | messages: before ++ [msg] ++ after_}
  end

  defp inject_snapshot_message(ctx, _), do: ctx

  defp find_system_prompt_index(messages) do
    Enum.find_index(messages, fn msg -> msg["role"] == "system" end) || 0
  end

  # 5-second timeout for git commands to prevent blocking the agent loop
  # on slow filesystems or large repositories.
  @git_timeout_ms 5_000

  defp run_git(workspace, args) do
    case System.cmd("git", String.split(args, " "),
           cd: workspace,
           stderr_to_stdout: true,
           timeout: @git_timeout_ms
         ) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp indent_lines(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map(fn line -> prefix <> line end)
    |> Enum.join("\n")
  end

  defp workspace_path(ctx), do: ctx.metadata[:workspace] || "/tmp"
end
