defmodule Agentic.AgentFS do
  @moduledoc """
  Agent Filesystem Materialization API.

  Provides a cross-platform way to expose skills and memories as real files
  to CLI-based coding agents (Claude, OpenCode, Codex, etc.).

  ## How it works

  1. Before starting a CLI agent session, `mount/1` creates a temp directory
     and populates it with skills and memories from the host application.
  2. The overlay directory is bind-mounted into the sandbox at the agent's
     expected path (e.g. `~/.claude/skills`).
  3. The agent reads/writes files normally.
  4. After the session, `unmount/1` syncs back any agent-created skills/memories
     and cleans up the temp directory.

  ## Configuration

  The host application provides a materializer module via ctx metadata:

      metadata: %{
        agent_fs_materializer: MyApp.AgentFS.Materializer,
        workspace: "my-project"
      }

  Agent paths (skill_path, memory_path) come from the ACP Discovery database
  or can be overridden per protocol.
  """

  alias Agentic.AgentFS.Overlay
  alias Agentic.Loop.Context
  alias Agentic.Protocol.ACP.Discovery

  require Logger

  @doc """
  Mount the agent filesystem overlay before starting a CLI session.

  Returns `{overlay_path, updated_ctx}` where overlay_path is the temp
  directory containing skills and memories.

  The overlay_path should be passed to the sandbox runner as an agent_dir
  with a custom mount point.
  """
  @spec mount(Context.t()) :: {String.t(), Context.t()} | :noop
  def mount(ctx) do
    materializer = ctx.metadata[:agent_fs_materializer]

    if materializer do
      do_mount(ctx, materializer)
    else
      Logger.debug("AgentFS: No materializer configured, skipping mount")
      :noop
    end
  end

  @doc """
  Unmount the agent filesystem overlay after a CLI session ends.

  Syncs back any agent-created skills and memories, then cleans up.
  """
  @spec unmount(Context.t()) :: :ok
  def unmount(ctx) do
    materializer = ctx.metadata[:agent_fs_materializer]
    overlay_path = ctx.agent_fs_overlay
    original_skills = ctx.agent_fs_original_skills || []

    if materializer and overlay_path do
      do_unmount(ctx, materializer, overlay_path, original_skills)
    else
      :ok
    end
  end

  @doc """
  Get the bind mount specification for the sandbox runner.

  Returns a list of `{host_path, container_path}` tuples for bind-mounting
  into the agent sandbox.
  """
  @spec bind_mounts(Context.t()) :: [{String.t(), String.t()}]
  def bind_mounts(ctx) do
    overlay_path = ctx.agent_fs_overlay

    if overlay_path do
      skill_path = agent_skill_path(ctx)
      memory_path = agent_memory_path(ctx)

      mounts = []

      mounts =
        if skill_path,
          do: [{Path.join(overlay_path, "skills"), skill_path} | mounts],
          else: mounts

      mounts =
        if memory_path,
          do: [{Path.join(overlay_path, "memory"), memory_path} | mounts],
          else: mounts

      mounts
    else
      []
    end
  end

  @doc """
  Look up the agent's expected skill path from the discovery database.
  """
  @spec agent_skill_path(Context.t()) :: String.t() | nil
  def agent_skill_path(ctx) do
    protocol = resolve_protocol_name(ctx)

    case Discovery.lookup_known(protocol) do
      nil -> nil
      entry -> entry[:skill_path]
    end
  end

  @doc """
  Look up the agent's expected memory path from the discovery database.
  """
  @spec agent_memory_path(Context.t()) :: String.t() | nil
  def agent_memory_path(ctx) do
    protocol = resolve_protocol_name(ctx)

    case Discovery.lookup_known(protocol) do
      nil -> nil
      entry -> entry[:memory_path]
    end
  end

  # --- Private ---

  defp do_mount(ctx, materializer) do
    {overlay_path, cleanup} = Overlay.create()
    Logger.info("AgentFS: Mounted overlay at #{overlay_path}")

    opts = [workspace: ctx.metadata[:workspace]]

    # Materialize skills
    skills = materializer.materialize_skills(opts)
    Overlay.write_skills(overlay_path, skills)
    Logger.debug("AgentFS: Materialized #{length(skills)} skills")

    # Materialize memories
    memory_content = materializer.materialize_memories(opts)

    if memory_content != "" do
      Overlay.write_memory(overlay_path, memory_content)
      Logger.debug("AgentFS: Materialized memories")
    end

    # Store overlay info in context
    updated_ctx = %{
      ctx
      | agent_fs_overlay: overlay_path,
        agent_fs_cleanup: cleanup,
        agent_fs_original_skills: Enum.map(skills, & &1.name),
        metadata:
          Map.put(
            ctx.metadata,
            :agent_fs_bind_mounts,
            bind_mounts_from_context(overlay_path, ctx)
          )
    }

    {overlay_path, updated_ctx}
  end

  defp do_unmount(ctx, materializer, overlay_path, original_skills) do
    Logger.info("AgentFS: Unmounting overlay #{overlay_path}")

    opts = [workspace: ctx.metadata[:workspace]]

    # Sync back skills
    skills_data = Overlay.read_skills(overlay_path, original_skills)

    if skills_data != [] do
      Logger.info("AgentFS: Syncing back #{length(skills_data)} skills")
      materializer.sync_back_skills(skills_data, opts)
    end

    # Sync back memories
    memory_content = Overlay.read_memory(overlay_path)

    if memory_content != "" do
      Logger.info("AgentFS: Syncing back memories")
      materializer.sync_back_memories(memory_content, opts)
    end

    # Cleanup
    cleanup = ctx.agent_fs_cleanup

    if cleanup do
      cleanup.()
    else
      File.rm_rf(overlay_path)
    end

    :ok
  end

  defp bind_mounts_from_context(overlay_path, ctx) do
    skill_path = agent_skill_path(ctx)
    memory_path = agent_memory_path(ctx)

    mounts = []

    mounts =
      if skill_path, do: [{Path.join(overlay_path, "skills"), skill_path} | mounts], else: mounts

    mounts =
      if memory_path,
        do: [{Path.join(overlay_path, "memory"), memory_path} | mounts],
        else: mounts

    mounts
  end

  defp resolve_protocol_name(ctx) do
    cond do
      ctx.profile == :claude_code ->
        :claude

      ctx.profile == :opencode ->
        :opencode

      ctx.profile == :codex ->
        :codex

      ctx.protocol_module ->
        module_name = ctx.protocol_module |> Module.split() |> List.last() |> String.downcase()
        String.to_atom(module_name)

      true ->
        nil
    end
  end
end
