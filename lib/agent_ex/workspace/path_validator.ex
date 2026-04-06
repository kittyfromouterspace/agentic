defmodule AgentEx.Workspace.PathValidator do
  @moduledoc """
  Validates workspace paths are within the allowed base directory.

  All workspace directories must be direct children of the configured
  `:workspace_base_dir`. This prevents path traversal attacks and ensures
  workspaces cannot write to arbitrary filesystem locations.
  """

  @doc """
  Returns the expanded base directory for all workspaces.
  """
  def base_dir do
    Application.get_env(:agent_ex, :workspace_base_dir, "~/.agent_ex/workspaces")
    |> Path.expand()
  end

  @doc """
  Generates a safe workspace path from a slug.

  The slug must match `^[a-z0-9][a-z0-9-]*$`. Returns `{:ok, path}` or
  `{:error, reason}`.
  """
  def from_slug(slug) when is_binary(slug) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, slug) do
      {:ok, Path.join(base_dir(), slug)}
    else
      {:error,
       "Invalid slug: must start with a letter or digit and contain only lowercase letters, digits, and hyphens"}
    end
  end

  def from_slug(_), do: {:error, "Slug must be a string"}

  @doc """
  Validates that a workspace path is safe and within the base directory.

  Rules:
  1. Expanded path must be a direct child of base_dir
  2. Must not escape via `..` traversal (checked after expansion)
  3. Must not be the base_dir itself
  4. Directory name must match `^[a-z0-9][a-z0-9-]*$`

  Returns `{:ok, expanded_path}` or `{:error, reason}`.
  """
  def validate(path) when is_binary(path) do
    base = base_dir()
    expanded = Path.expand(path)

    with :ok <- check_under_base(expanded, base),
         :ok <- check_direct_child(expanded, base),
         :ok <- check_safe_name(expanded, base) do
      {:ok, expanded}
    end
  end

  def validate(_), do: {:error, "Workspace path must be a string"}

  defp check_under_base(expanded, base) do
    if String.starts_with?(expanded, base <> "/") do
      :ok
    else
      {:error, "Workspace path must be within #{base}"}
    end
  end

  defp check_direct_child(expanded, base) do
    relative = Path.relative_to(expanded, base)

    if String.contains?(relative, "/") do
      {:error, "Workspace path must be a direct child of #{base}"}
    else
      :ok
    end
  end

  defp check_safe_name(expanded, _base) do
    name = Path.basename(expanded)

    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) do
      :ok
    else
      {:error,
       "Workspace directory name must start with a letter or digit and contain only lowercase letters, digits, and hyphens"}
    end
  end
end
