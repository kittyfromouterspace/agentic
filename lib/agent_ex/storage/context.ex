defmodule AgentEx.Storage.Context do
  @moduledoc "Bundles a storage backend module with its config for a specific workspace."

  @enforce_keys [:backend, :config]
  defstruct [:backend, :config]

  @type t :: %__MODULE__{backend: module(), config: map()}

  def for_workspace(workspace_root, backend_name \\ :local) do
    {mod, config} = resolve_backend(backend_name, workspace_root)
    %__MODULE__{backend: mod, config: config}
  end

  def read(%__MODULE__{backend: mod, config: cfg}, path), do: mod.read(cfg, path)

  def write(%__MODULE__{backend: mod, config: cfg}, path, content),
    do: mod.write(cfg, path, content)

  def exists?(%__MODULE__{backend: mod, config: cfg}, path), do: mod.exists?(cfg, path)
  def dir?(%__MODULE__{backend: mod, config: cfg}, path), do: mod.dir?(cfg, path)
  def ls(%__MODULE__{backend: mod, config: cfg}, path), do: mod.ls(cfg, path)
  def rm_rf(%__MODULE__{backend: mod, config: cfg}, path), do: mod.rm_rf(cfg, path)
  def mkdir_p(%__MODULE__{backend: mod, config: cfg}, path), do: mod.mkdir_p(cfg, path)

  def materialize_local(%__MODULE__{backend: mod, config: cfg}, path),
    do: mod.materialize_local(cfg, path)

  def workspace_root(%__MODULE__{config: cfg}), do: Map.fetch!(cfg, :root)

  defp resolve_backend(:local, workspace_root) do
    {AgentEx.Storage.Local, %{root: workspace_root}}
  end
end
