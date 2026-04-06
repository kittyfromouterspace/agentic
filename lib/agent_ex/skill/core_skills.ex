defmodule AgentEx.Skill.CoreSkills do
  @moduledoc """
  Manages bundled core skills that ship with every agent.

  Core skills live in `priv/core_skills/` and are auto-installed into
  workspaces on session start. They cannot be removed by the agent.

  ## Loading Modes

  Core skills declare a `loading` field in their frontmatter:

  - `"always"` — full body included in the system prompt
  - `"on_demand"` — listed by name only, loaded via `skill_read` when needed
  - `"trigger:<event>"` — not listed until triggered (e.g. onboarding)
  """

  alias AgentEx.Skill.Parser
  alias AgentEx.Storage.Context

  require Logger

  @skills_dir "skills"

  @doc """
  List all bundled core skills with parsed metadata.

  Returns `{:ok, [%{meta: ..., body: ...}]}` for all valid core skills.
  """
  @spec list() :: {:ok, [Parser.parsed_skill()]}
  def list do
    skills =
      core_skills_path()
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reduce([], fn dir, acc ->
        skill_md = Path.join([core_skills_path(), dir, "SKILL.md"])

        case Parser.parse_file(skill_md) do
          {:ok, parsed} ->
            [parsed | acc]

          {:error, reason} ->
            Logger.warning("Failed to parse core skill #{dir}: #{reason}")
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, skills}
  end

  @doc """
  Read a specific core skill by name.
  """
  @spec read(String.t()) :: {:ok, Parser.parsed_skill()} | {:error, String.t()}
  def read(name) do
    skill_md = Path.join([core_skills_path(), name, "SKILL.md"])

    if File.exists?(skill_md) do
      Parser.parse_file(skill_md)
    else
      {:error, "Core skill '#{name}' not found"}
    end
  end

  @doc """
  Get all core skills that should be included in the system prompt.

  Returns skills with `loading: "always"`.
  """
  @spec always_loaded() :: {:ok, [Parser.parsed_skill()]}
  def always_loaded do
    {:ok, all} = list()
    {:ok, Enum.filter(all, &(&1.meta.loading == "always"))}
  end

  @doc """
  Get all core skills that should be listed (not loaded) in the prompt.

  Returns skills with `loading: "on_demand"`.
  """
  @spec on_demand() :: {:ok, [Parser.parsed_skill()]}
  def on_demand do
    {:ok, all} = list()
    {:ok, Enum.filter(all, &(&1.meta.loading == "on_demand"))}
  end

  @doc """
  Get a core skill by its trigger event name.

  For skills with `loading: "trigger:<event>"`, returns the skill matching
  the given event.
  """
  @spec for_trigger(String.t()) :: {:ok, Parser.parsed_skill()} | :none
  def for_trigger(event) do
    {:ok, all} = list()

    case Enum.find(all, &(&1.meta.loading == "trigger:#{event}")) do
      nil -> :none
      skill -> {:ok, skill}
    end
  end

  @doc """
  Ensure core skills are installed in the workspace.

  Copies any missing core skill SKILL.md files into the workspace's
  `skills/` directory. Existing workspace skills with the same name
  are not overwritten.
  """
  @spec ensure_installed(String.t(), keyword()) :: :ok
  def ensure_installed(workspace_root, opts \\ []) do
    ctx = Keyword.get(opts, :storage) || Context.for_workspace(workspace_root)
    {:ok, core} = list()

    for skill <- core do
      name = skill.meta.name
      target = "#{@skills_dir}/#{name}/SKILL.md"

      if !Context.exists?(ctx, target) do
        Context.mkdir_p(ctx, "#{@skills_dir}/#{name}")
        Context.write(ctx, target, skill.raw)
        Logger.debug("Installed core skill '#{name}' into #{workspace_root}")
      end
    end

    :ok
  end

  @doc """
  Check if a skill name is a core skill (cannot be removed).
  """
  @spec core?(String.t()) :: boolean()
  def core?(name) do
    File.dir?(Path.join(core_skills_path(), name))
  end

  defp core_skills_path do
    Application.app_dir(:agent_ex, "priv/core_skills")
  end
end
