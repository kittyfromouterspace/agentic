defmodule Agentic.AgentFS.Materializer do
  @moduledoc """
  Behaviour for materializing skills and memories into the agent's filesystem.

  Host applications implement this behaviour and pass the module via
  `ctx.metadata[:agent_fs_materializer]`.

  ## Usage

      defmodule MyApp.AgentFS.Materializer do
        @behaviour Agentic.AgentFS.Materializer

        @impl true
        def materialize_skills(opts) do
          # Return list of %{name: ..., content: ...}
        end

        @impl true
        def materialize_memories(opts) do
          # Return string of formatted memory content
        end

        @impl true
        def sync_back_skills(skills_data, opts) do
          # Persist agent-created skills
        end

        @impl true
        def sync_back_memories(memory_content, opts) do
          # Persist agent-created memories
        end
      end
  """

  @type skill_data :: %{name: String.t(), content: String.t()}
  @type skills_data :: [skill_data()]
  @type opts :: keyword()

  @doc """
  Materialize skills for the agent filesystem.

  Returns a list of `%{name: ..., content: ...}` maps. Each skill will be
  written as `<skill_path>/<name>/SKILL.md` in the overlay.
  """
  @callback materialize_skills(opts) :: skills_data

  @doc """
  Materialize memories for the agent filesystem.

  Returns a string that will be written to `<memory_path>/MEMORY.md`.
  """
  @callback materialize_memories(opts) :: String.t()

  @doc """
  Sync back skills created by the agent.

  `skills_data` is a list of `%{name: ..., content: ..., is_new: bool}` maps
  for skills that were modified or created during the session.
  """
  @callback sync_back_skills(skills_data, opts) :: :ok

  @doc """
  Sync back memories modified by the agent.

  `memory_content` is the full text of the memory file after the session.
  """
  @callback sync_back_memories(String.t(), opts) :: :ok
end
