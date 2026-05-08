defmodule Agentic.Sandbox.Runner do
  @moduledoc """
  Cross-platform sandbox wrapper for agent subprocesses.

  Provides a single entry point that selects the correct OS-level
  isolation mechanism based on `Agentic.Sandbox.Platform.backend/0`.

  Supports two invocation styles:
  - `wrap_shell/2` — for arbitrary shell commands (e.g. the `bash` tool)
  - `wrap_executable/3` — for executable + argument list (e.g. coding agents)
  """

  alias Agentic.Sandbox.Platform

  require Logger

  @doc """
  Wraps a shell command string in the platform-appropriate sandbox.

  Returns a string that can be passed to `Port.open({:spawn, command}, ...)`.
  """
  @spec wrap_shell(String.t(), keyword()) :: String.t()
  def wrap_shell(command, opts \\ []) when is_binary(command) do
    workspace = Keyword.fetch!(opts, :workspace)
    agent_dirs = Keyword.get(opts, :agent_dirs, [])

    case Platform.backend() do
      :bubblewrap ->
        bwrap_shell(command, workspace, agent_dirs)

      :wsl2_bwrap ->
        wsl2_bwrap_shell(command, workspace, agent_dirs)

      :macos_sandbox ->
        # macOS App Sandbox is inherited from the parent process;
        # no wrapper needed here.
        command

      :windows_restricted ->
        log_windows_warning()
        command
    end
  end

  @doc """
  Wraps an executable path and argument list in the platform-appropriate sandbox.

  Returns `{executable, args, extra_env}` suitable for
  `Port.open({:spawn_executable, executable}, [:binary, :exit_status, {:args, args} | extra_env])`.
  """
  @spec wrap_executable(String.t(), [String.t()], keyword()) ::
          {String.t(), [String.t()], keyword()}
  def wrap_executable(executable, args, opts \\ []) do
    workspace = Keyword.fetch!(opts, :workspace)
    agent_dirs = Keyword.get(opts, :agent_dirs, [])

    case Platform.backend() do
      :bubblewrap ->
        bwrap_executable(executable, args, workspace, agent_dirs)

      :wsl2_bwrap ->
        wsl2_bwrap_executable(executable, args, workspace, agent_dirs)

      :macos_sandbox ->
        {executable, args, []}

      :windows_restricted ->
        log_windows_warning()
        {executable, args, []}
    end
  end

  # --- Linux bubblewrap ---

  defp bwrap_shell(command, workspace, agent_dirs) do
    bwrap = bwrap_executable()
    args = bwrap_args(workspace, agent_dirs, network: :block)
    "#{bwrap} #{args} -- /bin/sh -c #{shell_escape(command)}"
  end

  defp bwrap_executable(executable, args, workspace, agent_dirs) do
    bwrap = bwrap_executable()

    bwrap_args_list =
      bwrap_args_list(workspace, agent_dirs, network: :allow) ++
        executable_bind_args(executable)

    {bwrap, bwrap_args_list ++ ["--", executable] ++ args, []}
  end

  # Bind-mount the executable's path (and any symlink targets it resolves to)
  # so bwrap can exec it from inside the sandbox. This covers CLIs installed
  # under user-local prefixes like ~/.local/bin, ~/.npm-global/bin, nvm, asdf, etc.
  defp executable_bind_args(executable) when is_binary(executable) do
    chain = symlink_chain(executable, [])

    parents =
      chain
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()
      |> Enum.reject(&bwrap_base_bound?/1)

    tool_manager_roots =
      chain
      |> Enum.flat_map(&tool_manager_root/1)
      |> Enum.uniq()
      |> Enum.reject(&bwrap_base_bound?/1)

    (parents ++ tool_manager_roots)
    |> Enum.uniq()
    |> Enum.flat_map(fn dir -> ["--ro-bind-try", dir, dir] end)
  end

  defp executable_bind_args(executable) when is_list(executable),
    do: executable_bind_args(List.to_string(executable))

  defp executable_bind_args(_), do: []

  # Detect version-manager layouts (asdf, mise, nvm, rbenv, ...). Shims live
  # in `$ROOT/shims/` but dispatch into `$ROOT/installs/...`, so binding just
  # the shim directory isn't enough — we need the whole manager tree.
  @tool_managers ~w(.asdf .mise .nvm .rbenv .pyenv .nodenv .jenv)
  defp tool_manager_root(path) do
    Enum.find_value(@tool_managers, [], fn name ->
      marker = "/" <> name <> "/"

      case String.split(path, marker, parts: 2) do
        [prefix, _] -> [prefix <> "/" <> name]
        _ -> nil
      end
    end)
  end

  defp symlink_chain(_path, acc) when length(acc) > 16, do: Enum.reverse(acc)

  defp symlink_chain(path, acc) do
    acc = [path | acc]

    case File.read_link(path) do
      {:ok, target} ->
        resolved =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(path))

        if resolved in acc, do: Enum.reverse(acc), else: symlink_chain(resolved, acc)

      _ ->
        Enum.reverse(acc)
    end
  end

  defp bwrap_base_bound?(dir) do
    Enum.any?(["/usr", "/bin", "/lib", "/lib64", "/etc"], fn base ->
      dir == base or String.starts_with?(dir, base <> "/")
    end)
  end

  defp bwrap_executable do
    bundled = bundled_bwrap_path()

    if bundled != nil and File.exists?(bundled) do
      bundled
    else
      case System.find_executable("bwrap") do
        nil ->
          Logger.warning(
            "Agentic.Sandbox: bwrap not found in PATH. " <>
              "Falling back to system bwrap (may fail)."
          )

          "bwrap"

        exe ->
          exe
      end
    end
  end

  defp bundled_bwrap_path do
    case :os.type() do
      {:unix, :linux} ->
        # Prefer a bundled static binary in the OTP release priv dir
        priv = Application.app_dir(:agentic, "priv/bin/bwrap")
        if File.exists?(priv), do: priv

      _ ->
        nil
    end
  end

  defp bwrap_args(workspace, agent_dirs, opts) do
    workspace |> bwrap_args_list(agent_dirs, opts) |> Enum.map_join(" ", &shell_escape/1)
  end

  defp bwrap_args_list(workspace, agent_dirs, opts) do
    network = Keyword.get(opts, :network, :block)

    # `--unshare-all` unshares the network namespace too, which breaks
    # agent CLIs that need API access. When network: :allow is requested,
    # we unshare every namespace except net.
    unshare_flags =
      case network do
        :block ->
          ["--unshare-all"]

        :allow ->
          [
            "--unshare-user",
            "--unshare-pid",
            "--unshare-uts",
            "--unshare-ipc",
            "--unshare-cgroup-try"
          ]
      end

    base =
      [
        "--ro-bind",
        "/usr",
        "/usr",
        "--ro-bind",
        "/bin",
        "/bin",
        "--ro-bind",
        "/lib",
        "/lib",
        "--ro-bind",
        "/lib64",
        "/lib64",
        "--ro-bind",
        "/etc",
        "/etc",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--dir",
        "/run"
      ] ++
        unshare_flags ++
        [
          "--die-with-parent",
          "--chdir",
          "/workspace"
        ] ++
        bind_args(workspace, "/workspace", :rw)

    # Agent private dirs (config/cache/logs) are bound at their original
    # host paths so the CLI's own `$HOME/...` lookups resolve correctly.
    #
    # Supports both plain strings (bind at same path) and {host, container}
    # tuples for custom mount points (e.g. AgentFS overlays).
    agent_binds =
      Enum.flat_map(agent_dirs, fn
        {host_path, container_path} -> bind_args(host_path, container_path, :rw)
        dir when is_binary(dir) -> bind_args(dir, dir, :rw)
      end)

    base ++ agent_binds
  end

  defp bind_args(host_path, container_path, :rw) do
    if File.dir?(host_path) or not File.exists?(host_path) do
      # Ensure the directory exists so bwrap can bind-mount it
      File.mkdir_p!(host_path)
      ["--bind", host_path, container_path]
    else
      # Host path is a file; bind it as a file
      ["--bind", host_path, container_path]
    end
  end

  # --- WSL2 bubblewrap ---

  defp wsl2_bwrap_shell(command, workspace, agent_dirs) do
    ws_wsl = windows_to_wsl_path(workspace)
    dirs_wsl = Enum.map(agent_dirs, &windows_to_wsl_path/1)

    args =
      ws_wsl
      |> bwrap_args_list(dirs_wsl, network: :block)
      |> Enum.map_join(" ", &shell_escape/1)

    "wsl.exe -- bwrap #{args} --chdir /workspace -- /bin/sh -c #{shell_escape(command)}"
  end

  defp wsl2_bwrap_executable(executable, args, workspace, agent_dirs) do
    ws_wsl = windows_to_wsl_path(workspace)
    dirs_wsl = Enum.map(agent_dirs, &windows_to_wsl_path/1)

    bwrap_args_list =
      bwrap_args_list(ws_wsl, dirs_wsl, network: :allow) ++
        executable_bind_args(executable)

    {"wsl.exe",
     ["--", "bwrap"] ++ bwrap_args_list ++ ["--chdir", "/workspace", "--", executable] ++ args,
     []}
  end

  defp windows_to_wsl_path(<<drive::binary-size(1), ":", rest::binary>>) do
    "/mnt/#{String.downcase(drive)}#{String.replace(rest, "\\", "/")}"
  end

  defp windows_to_wsl_path(path) do
    String.replace(path, "\\", "/")
  end

  # --- Helpers ---

  defp shell_escape(str) do
    # Simple single-quote escaping for shell safety
    "'" <> String.replace(str, "'", "'\"'\"'") <> "'"
  end

  defp log_windows_warning do
    case Platform.warning() do
      nil -> :ok
      msg -> Logger.warning("Agentic.Sandbox.Runner: #{msg}")
    end
  end
end
