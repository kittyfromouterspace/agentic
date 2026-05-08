defmodule Agentic.AgentFS.Overlay do
  @moduledoc """
  Manages temporary overlay directories for agent filesystem materialization.

  Creates a temp directory, writes skills and memories into it, and
  provides paths for bind-mounting into the agent sandbox.
  """

  require Logger

  @doc """
  Create a new overlay directory for a session.

  Returns `{overlay_path, cleanup_fn}` where `cleanup_fn` is a 0-arity
  function that deletes the overlay directory.
  """
  @spec create() :: {String.t(), (-> :ok)}
  def create do
    overlay_path = Path.join(System.tmp_dir!(), "agentic-" <> random_id())
    File.mkdir_p!(overlay_path)

    cleanup = fn ->
      case File.rm_rf(overlay_path) do
        {:ok, _} ->
          :ok

        {:error, reason, _} ->
          Logger.warning("AgentFS: Failed to cleanup overlay #{overlay_path}: #{reason}")
          :ok
      end
    end

    {overlay_path, cleanup}
  end

  @doc """
  Write skills into the overlay directory.

  Skills are written as `skills/<name>/SKILL.md`.
  """
  @spec write_skills(String.t(), [map()]) :: :ok
  def write_skills(overlay_path, skills) do
    skills_dir = Path.join(overlay_path, "skills")
    File.mkdir_p!(skills_dir)

    for %{name: name, content: content} <- skills do
      skill_dir = Path.join(skills_dir, name)
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), content)
    end

    :ok
  end

  @doc """
  Write memory content into the overlay directory.

  Memory is written as `memory/MEMORY.md`.
  """
  @spec write_memory(String.t(), String.t()) :: :ok
  def write_memory(overlay_path, content) do
    memory_dir = Path.join(overlay_path, "memory")
    File.mkdir_p!(memory_dir)
    File.write!(Path.join(memory_dir, "MEMORY.md"), content)
    :ok
  end

  @doc """
  Read back skills that were created or modified by the agent.

  Returns list of `%{name: ..., content: ..., is_new: bool}`.
  """
  @spec read_skills(String.t(), [String.t()]) :: [map()]
  def read_skills(overlay_path, original_names) do
    skills_dir = Path.join(overlay_path, "skills")
    original_set = MapSet.new(original_names)

    if File.dir?(skills_dir) do
      skills_dir
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(skills_dir, &1)))
      |> Enum.map(fn name ->
        skill_file = Path.join([skills_dir, name, "SKILL.md"])

        if File.exists?(skill_file) do
          content = File.read!(skill_file)

          %{
            name: name,
            content: content,
            is_new: not MapSet.member?(original_set, name)
          }
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  @doc """
  Read back memory content modified by the agent.
  """
  @spec read_memory(String.t()) :: String.t()
  def read_memory(overlay_path) do
    memory_file = Path.join(overlay_path, "memory/MEMORY.md")

    if File.exists?(memory_file) do
      File.read!(memory_file)
    else
      ""
    end
  end

  defp random_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
