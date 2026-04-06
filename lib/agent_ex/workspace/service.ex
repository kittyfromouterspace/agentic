defmodule AgentEx.Workspace.Service do
  @moduledoc """
  Manages workspace file structure and policy.

  Creates and maintains the workspace directory structure:
    workspace/
    ├── AGENTS.md              # Boot sequence & operating guidelines
    ├── TOOLS.md               # Available tools & credentials
    ├── MEMORY.md              # Curated long-term memory
    ├── HEARTBEAT.md           # Periodic task config
    ├── memory/
    │   └── YYYY-MM-DD.md      # Daily logs
    └── policy/
        └── policy.yaml        # Tool permissions

  Identity files (SOUL.md, IDENTITY.md, USER.md) are created by the agent
  during the onboarding conversation, not scaffolded here.
  """

  require Logger

  alias AgentEx.Storage.Context
  alias AgentEx.Workspace.Templates

  @policy_file "policy.yaml"

  @doc "Get the allowed roots for a workspace."
  def get_roots(workspace_root) do
    {:ok, [Path.join(workspace_root, ".")]}
  end

  @doc """
  Create a new workspace with the full directory structure.

  Options:
  - `:workspace_type` — `:general`, `:personal`, `:admin`, `:team`, or `:task` (default: `:general`)
  - `:workspace_template` — `:standard` (default: `:standard`)
  - `:storage` — a `%Storage.Context{}` (default: local backend for workspace_root)
  """
  def create_workspace(workspace_root, opts \\ []) do
    workspace_type = Keyword.get(opts, :workspace_type, :general)
    ctx = Keyword.get(opts, :storage) || Context.for_workspace(workspace_root)
    create_workspace_structure(ctx, workspace_type)
    :ok
  end

  @doc "Set the workspace policy."
  def set_policy(workspace_root, policy, storage \\ nil) do
    ctx = storage || Context.for_workspace(workspace_root)
    save_policy(ctx, policy)
  end

  @doc "Get the default workspace policy."
  def get_policy do
    {:ok, default_policy()}
  end

  @doc "Get the memory directory for a workspace."
  def get_memory_dir(_workspace_root) do
    {:ok, "memory"}
  end

  @doc """
  Copy identity files (SOUL.md, IDENTITY.md, USER.md) from a source workspace
  to a destination workspace. AGENTS.md is intentionally excluded as it is
  workspace-specific and always scaffolded fresh.
  """
  def copy_identity_files(source_workspace_path, dest_workspace_path) do
    source_ctx = Context.for_workspace(source_workspace_path)
    dest_ctx = Context.for_workspace(dest_workspace_path)

    Enum.each(AgentEx.Workspace.Identity.identity_files(), fn file ->
      case Context.read(source_ctx, file) do
        {:ok, content} ->
          Context.write(dest_ctx, file, content)
          Logger.info("Copied #{file} from #{source_workspace_path}")

        {:error, _} ->
          :ok
      end
    end)
  end

  @doc "Create a daily log file for today."
  def create_daily_log(workspace_root, storage \\ nil) do
    ctx = storage || Context.for_workspace(workspace_root)
    date = Date.utc_today()
    log_path = "memory/#{date}.md"

    case Context.write(ctx, log_path, Templates.daily_log_md(date)) do
      :ok -> {:ok, log_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Ensure the workspace base directory exists."
  def ensure_base_dir! do
    base = AgentEx.Workspace.PathValidator.base_dir()
    File.mkdir_p!(base)
  end

  # Private functions

  defp create_workspace_structure(ctx, workspace_type) do
    # Directories common to all workspace types
    Context.mkdir_p(ctx, ".")
    Context.mkdir_p(ctx, "policy")
    Context.mkdir_p(ctx, "memory")

    if workspace_type == :task do
      # Task workspaces get a coordinator-specific AGENTS.md and minimal scaffolding
      Context.write(ctx, "AGENTS.md", Templates.task_agents_md())
      write_if_missing(ctx, "TASK.md", Templates.task_brief_md())
      write_if_missing(ctx, "MEMORY.md", Templates.memory_md())
      Context.mkdir_p(ctx, "scratch")
    else
      # Standard workspaces get the full template set
      Context.mkdir_p(ctx, "skills")
      seed_default_skills(ctx)

      write_if_missing(ctx, "AGENTS.md", Templates.agents_md())
      write_if_missing(ctx, "MEMORY.md", Templates.memory_md())
      write_if_missing(ctx, "TOOLS.md", Templates.tools_md())
      write_if_missing(ctx, "HEARTBEAT.md", Templates.heartbeat_md())
      write_if_missing(ctx, "CAPABILITIES.md", Templates.capabilities_md())

      if workspace_type == :team do
        write_if_missing(ctx, "TEAM.md", Templates.team_md())
      end
    end

    create_daily_log_file(ctx)
    save_policy(ctx, default_policy())

    :ok
  end

  defp seed_default_skills(ctx) do
    write_if_missing(ctx, "skills/skill-search/SKILL.md", Templates.skill_search_md())
  end

  defp write_if_missing(ctx, filename, content) do
    unless Context.exists?(ctx, filename) do
      Context.write(ctx, filename, content)
      Logger.info("Created #{filename}")
    end
  end

  defp create_daily_log_file(ctx) do
    date = Date.utc_today()
    log_path = "memory/#{date}.md"

    unless Context.exists?(ctx, log_path) do
      Context.write(ctx, log_path, Templates.daily_log_md(date))
      Logger.info("Created daily log: #{log_path}")
    end
  end

  defp save_policy(ctx, policy) do
    policy_path = Path.join("policy", @policy_file)

    case Context.write(ctx, policy_path, Jason.encode!(policy, pretty: true)) do
      :ok ->
        Logger.info("Policy saved")
        :ok

      {:error, reason} ->
        Logger.error("Failed to save policy: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp default_policy do
    %{
      tools: %{
        "file_operations" => %{
          "enabled" => true,
          "allowed_roots" => ["."],
          "max_file_size_mb" => 10
        },
        "git_operations" => %{
          "enabled" => true,
          "allowed_repos" => [],
          "max_changes" => 100
        },
        "code_execution" => %{
          "enabled" => false,
          "sandbox_backend" => "podman"
        }
      },
      permissions: %{
        "allow_session_creation" => true,
        "allow_workspace_modification" => true
      }
    }
  end
end
