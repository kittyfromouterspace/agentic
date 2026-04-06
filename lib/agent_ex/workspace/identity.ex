defmodule AgentEx.Workspace.Identity do
  @moduledoc """
  Workspace identity file detection and status.

  Determines workspace identity status: fresh (no files), partial (some),
  or established (all present). Used by ContextAssembler for prompt assembly.
  """

  alias AgentEx.Storage.Context

  @identity_files ~w(SOUL.md IDENTITY.md USER.md)
  @all_files ~w(AGENTS.md SOUL.md IDENTITY.md USER.md TOOLS.md MEMORY.md HEARTBEAT.md)

  @type status :: :fresh | :partial | :established

  @doc """
  Check the identity status of a workspace.

  Returns a map with:
  - `:status` — `:fresh` (no identity files), `:partial` (some), or `:established` (all three)
  - `:present` — list of existing identity files
  - `:missing` — list of missing identity files
  """
  @spec check(String.t() | Context.t()) :: %{
          status: status(),
          present: [String.t()],
          missing: [String.t()]
        }
  def check(%Context{} = ctx) do
    {present, missing} =
      Enum.split_with(@identity_files, fn file ->
        Context.exists?(ctx, file)
      end)

    status =
      cond do
        missing == [] -> :established
        present == [] -> :fresh
        true -> :partial
      end

    %{status: status, present: present, missing: missing}
  end

  def check(workspace_root) when is_binary(workspace_root) do
    check(Context.for_workspace(workspace_root))
  end

  @doc """
  Read all workspace files, returning a map of filename to content.

  Missing files have `nil` as their value.
  """
  @spec read_all_files(String.t() | Context.t()) :: %{String.t() => String.t() | nil}
  def read_all_files(%Context{} = ctx) do
    Map.new(@all_files, fn file ->
      content =
        case Context.read(ctx, file) do
          {:ok, data} -> data
          {:error, _} -> nil
        end

      {file, content}
    end)
  end

  def read_all_files(workspace_root) when is_binary(workspace_root) do
    read_all_files(Context.for_workspace(workspace_root))
  end

  @doc "The list of core identity files that trigger onboarding."
  def identity_files, do: @identity_files

  @doc "The list of all workspace files."
  def all_files, do: @all_files
end
