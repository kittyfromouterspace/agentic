defmodule AgentEx.Storage.Local do
  @moduledoc "Local filesystem storage backend."

  def name, do: :local

  def read(config, path) do
    config.root |> resolve_path(path) |> File.read()
  end

  def write(config, path, content) do
    full = resolve_path(config.root, path)
    full |> Path.dirname() |> File.mkdir_p!()
    File.write(full, content)
  end

  def exists?(config, path), do: config.root |> resolve_path(path) |> File.exists?()
  def dir?(config, path), do: config.root |> resolve_path(path) |> File.dir?()
  def ls(config, path), do: config.root |> resolve_path(path) |> File.ls()

  def rm_rf(config, path) do
    config.root |> resolve_path(path) |> File.rm_rf!()
    :ok
  end

  def mkdir_p(config, path), do: config.root |> resolve_path(path) |> File.mkdir_p()
  def materialize_local(config, path), do: {:ok, resolve_path(config.root, path)}

  defp resolve_path(root, "."), do: root
  defp resolve_path(root, path), do: Path.join(root, path)
end
