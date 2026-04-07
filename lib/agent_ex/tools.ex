defmodule AgentEx.Tools do
  @moduledoc """
  Tool definitions and execution for the agent loop.

  Core file tools (read_file, write_file, edit_file, bash, list_files) are
  defined inline. Extended tools (skills, memory, gateway) are in submodules.

  All tool definition maps use **string keys** to stay consistent with
  the rest of the chat pipeline (messages, content blocks, LLM responses).
  """

  alias __MODULE__.Gateway
  alias __MODULE__.Memory
  alias __MODULE__.Skill
  alias AgentEx.Subagent.DelegateTask

  require Logger

  @max_bash_timeout 300_000
  @max_output_bytes 1_000_000

  @extension_modules [
    Skill,
    Gateway,
    Memory
  ]

  def definitions do
    file_tools() ++
      [DelegateTask.definition()] ++ Enum.flat_map(@extension_modules, & &1.definitions())
  end

  defp file_tools do
    [
      %{
        "name" => "read_file",
        "description" =>
          "Read the contents of a file. Returns the file content with line numbers. " <>
            "Use offset and limit to read specific line ranges for large files.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "File path relative to workspace"},
            "offset" => %{
              "type" => "integer",
              "description" => "Starting line number (1-based, optional)"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Number of lines to read (optional)"
            }
          },
          "required" => ["path"]
        }
      },
      %{
        "name" => "write_file",
        "description" =>
          "Create or overwrite a file. Parent directories are created automatically.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "File path relative to workspace"},
            "content" => %{"type" => "string", "description" => "File content to write"}
          },
          "required" => ["path", "content"]
        }
      },
      %{
        "name" => "edit_file",
        "description" =>
          "Make a surgical edit to a file by replacing exact text. " <>
            "old_text must match exactly (including whitespace and indentation).",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "File path relative to workspace"},
            "old_text" => %{"type" => "string", "description" => "Exact text to find and replace"},
            "new_text" => %{"type" => "string", "description" => "Replacement text"}
          },
          "required" => ["path", "old_text", "new_text"]
        }
      },
      %{
        "name" => "bash",
        "description" =>
          "Execute a shell command in the workspace directory. " <>
            "Use for running scripts, installing packages, git operations, etc.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string", "description" => "Shell command to execute"},
            "timeout" => %{
              "type" => "integer",
              "description" => "Timeout in seconds (default 60, max 300)"
            }
          },
          "required" => ["command"]
        }
      },
      %{
        "name" => "list_files",
        "description" =>
          "List files matching a glob pattern in the workspace. " <>
            "Defaults to listing all files. Use patterns like '**/*.ex' or 'lib/**'.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{"type" => "string", "description" => "Glob pattern (default: '**/*')"}
          }
        }
      }
    ]
  end

  # ── Tool Execution ──────────────────────────────────────────────────

  def execute(tool_name, input, ctx)
      when tool_name in ~w(read_file write_file edit_file bash list_files) do
    workspace = ctx.metadata[:workspace] || ctx.metadata["workspace"]
    execute_file_tool(tool_name, input, workspace)
  end

  def execute("delegate_task", input, ctx) do
    DelegateTask.execute(input, ctx)
  end

  def execute(tool_name, input, ctx) do
    case dispatch_to_extension(tool_name, input, ctx) do
      :not_handled -> {:error, "Unknown tool: #{tool_name}"}
      result -> result
    end
  end

  defp dispatch_to_extension(tool_name, input, ctx) do
    Enum.find_value(@extension_modules, :not_handled, fn mod ->
      case mod.execute(tool_name, input, ctx) do
        :not_handled -> nil
        result -> result
      end
    end)
  end

  # ── File Tools ─────────────────────────────────────────────────────

  defp execute_file_tool("read_file", input, workspace) do
    path = resolve_path(input["path"], workspace)

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        offset = max((input["offset"] || 1) - 1, 0)
        limit = input["limit"] || length(lines)

        numbered =
          lines
          |> Enum.with_index(1)
          |> Enum.slice(offset, limit)
          |> Enum.map_join("\n", fn {line, num} -> "#{num}\t#{line}" end)

        {:ok, numbered}

      {:error, :enoent} ->
        {:error, "File not found: #{input["path"]}"}

      {:error, reason} ->
        {:error, "Failed to read #{input["path"]}: #{inspect(reason)}"}
    end
  end

  defp execute_file_tool("write_file", input, workspace) do
    path = resolve_path(input["path"], workspace)
    content = input["content"] || ""

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, "Written #{byte_size(content)} bytes to #{input["path"]}"}
    else
      {:error, reason} ->
        {:error, "Failed to write #{input["path"]}: #{inspect(reason)}"}
    end
  end

  defp execute_file_tool("edit_file", input, workspace) do
    path = resolve_path(input["path"], workspace)
    old_text = input["old_text"]
    new_text = input["new_text"]

    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, old_text) do
          count = count_occurrences(content, old_text)

          if count > 1 do
            {:error,
             "old_text matches #{count} locations in #{input["path"]}. " <>
               "Provide more context to make it unique."}
          else
            updated = String.replace(content, old_text, new_text, global: false)

            case File.write(path, updated) do
              :ok -> {:ok, "Edited #{input["path"]}"}
              {:error, reason} -> {:error, "Failed to write #{input["path"]}: #{inspect(reason)}"}
            end
          end
        else
          {:error, "old_text not found in #{input["path"]}. Make sure it matches exactly."}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{input["path"]}"}

      {:error, reason} ->
        {:error, "Failed to read #{input["path"]}: #{inspect(reason)}"}
    end
  end

  defp execute_file_tool("bash", input, workspace) do
    command = input["command"]
    timeout_s = min(input["timeout"] || 60, div(@max_bash_timeout, 1000))
    timeout_ms = timeout_s * 1000

    try do
      port =
        Port.open({:spawn, command}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:cd, workspace}
        ])

      collect_port_output(port, "", timeout_ms)
    rescue
      e ->
        {:error, "Failed to execute command: #{Exception.message(e)}"}
    end
  end

  defp execute_file_tool("list_files", input, workspace) do
    pattern = input["pattern"] || "**/*"
    full_pattern = Path.join(workspace, pattern)

    files =
      full_pattern
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, workspace))
      |> Enum.sort()

    if files == [] do
      {:ok, "No files matching '#{pattern}'"}
    else
      {:ok, Enum.join(files, "\n")}
    end
  end

  defp resolve_path(relative_path, workspace) do
    # Prevent directory traversal
    clean = Path.expand(Path.join(workspace, relative_path))

    if String.starts_with?(clean, workspace) do
      clean
    else
      raise ArgumentError, "Path traversal detected: #{relative_path}"
    end
  end

  defp count_occurrences(string, substring) do
    parts = String.split(string, substring)
    length(parts) - 1
  end

  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, chunk}} ->
        new_acc = acc <> chunk

        if byte_size(new_acc) > @max_output_bytes do
          Port.close(port)
          truncated = String.slice(new_acc, 0, @max_output_bytes)
          {:ok, truncated <> "\n[output truncated at 1MB]"}
        else
          collect_port_output(port, new_acc, timeout)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:ok, "#{acc}\n[exit code: #{code}]"}
    after
      timeout ->
        Port.close(port)
        {:error, "Command timed out after #{div(timeout, 1000)}s\n#{acc}"}
    end
  end
end
