defmodule AgentEx.Skill.Service do
  @moduledoc """
  Workspace-scoped skill management.

  Skills are folders in `workspace/skills/<name>/` containing a SKILL.md file
  (YAML frontmatter + markdown body) and optional `scripts/`, `references/`,
  and `assets/` directories.

  Supports installing skills from GitHub repos in `owner/repo` or
  `owner/repo/subpath` format, and searching via the GitHub code search API.

  ## GitHub Authentication

  GitHub API calls work without authentication for public repos (with lower
  rate limits). To use authenticated requests, pass a `:get_secret` callback
  in opts:

      Service.search("query", get_secret: fn service, key -> {:ok, token} end)

  The callback receives `("github", "api_key")` and should return
  `{:ok, token}` or `:error`.
  """

  alias AgentEx.Skill.Analyzer
  alias AgentEx.Skill.CoreSkills
  alias AgentEx.Skill.Parser
  alias AgentEx.Storage.Context

  require Logger

  @skills_dir "skills"
  @github_api "https://api.github.com"
  @timeout 15_000
  @max_file_size 1_024 * 1_024

  # --- Local operations ---

  @doc """
  List installed skills with name and description summaries.

  Options:
  - `:storage` — a `%Storage.Context{}` (default: local backend for workspace_root)
  """
  @spec list(String.t(), keyword()) :: {:ok, [%{name: String.t(), description: String.t()}]}
  def list(workspace_root, opts \\ []) do
    ctx = Keyword.get(opts, :storage) || Context.for_workspace(workspace_root)

    if Context.dir?(ctx, @skills_dir) do
      case Context.ls(ctx, @skills_dir) do
        {:ok, entries} ->
          summaries =
            entries
            |> Enum.sort()
            |> Enum.reduce([], fn entry, acc ->
              skill_dir = "#{@skills_dir}/#{entry}"
              skill_md = "#{@skills_dir}/#{entry}/SKILL.md"

              if Context.dir?(ctx, skill_dir) and Context.exists?(ctx, skill_md) do
                case Context.read(ctx, skill_md) do
                  {:ok, content} ->
                    case Parser.parse(content) do
                      {:ok, parsed} ->
                        skill = %{name: parsed.meta.name, description: parsed.meta.description}

                        skill =
                          if parsed.meta.source,
                            do: Map.put(skill, :source, parsed.meta.source),
                            else: skill

                        [skill | acc]

                      {:error, _} ->
                        acc
                    end

                  {:error, _} ->
                    acc
                end
              else
                acc
              end
            end)
            |> Enum.reverse()

          {:ok, summaries}

        {:error, _} ->
          {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Read the full parsed SKILL.md content for an installed skill.

  Options:
  - `:storage` — a `%Storage.Context{}`
  """
  @spec read(String.t(), String.t(), keyword()) ::
          {:ok, Parser.parsed_skill()} | {:error, String.t()}
  def read(workspace_root, skill_name, opts \\ []) do
    ctx = Keyword.get(opts, :storage) || Context.for_workspace(workspace_root)

    with :ok <- validate_skill_name(skill_name) do
      skill_md = "#{@skills_dir}/#{skill_name}/SKILL.md"

      if Context.exists?(ctx, skill_md) do
        case Context.read(ctx, skill_md) do
          {:ok, content} -> Parser.parse(content)
          {:error, reason} -> {:error, "Failed to read skill: #{inspect(reason)}"}
        end
      else
        {:error, "Skill '#{skill_name}' not found"}
      end
    end
  end

  @doc """
  Remove an installed skill from the workspace.

  Options:
  - `:storage` — a `%Storage.Context{}`
  """
  @spec remove(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def remove(workspace_root, skill_name, opts \\ []) do
    ctx = Keyword.get(opts, :storage) || Context.for_workspace(workspace_root)

    with :ok <- validate_skill_name(skill_name) do
      if CoreSkills.core?(skill_name) do
        {:error, "Cannot remove core skill '#{skill_name}'"}
      else
        skill_dir = "#{@skills_dir}/#{skill_name}"

        if Context.dir?(ctx, skill_dir) do
          result = Context.rm_rf(ctx, skill_dir)
          update_capabilities_md(workspace_root, :remove, skill_name, opts)
          result
        else
          {:error, "Skill '#{skill_name}' not found"}
        end
      end
    end
  end

  # --- Remote operations ---

  @doc """
  Search for skills using the Vercel skills CLI (`npx skills find`).

  Falls back to GitHub code search API if `npx` is not available.
  The skills CLI does not require authentication.

  Options:
  - `:get_secret` — callback `fn(service, key) -> {:ok, token} | :error end`
    for GitHub API authentication. Falls back to `GITHUB_TOKEN` env var.
  - Other options forwarded to `Req` for testing.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def search(query, opts \\ []) do
    case search_skills_cli(query) do
      {:ok, results} ->
        {:ok, results}

      {:error, :cli_unavailable} ->
        token = github_token(opts)

        if is_nil(token) do
          {:error,
           "Skills CLI (bun) not available and no GitHub token set. " <>
             "Install bun or set GITHUB_TOKEN."}
        else
          search_github(query, token, opts)
        end
    end
  end

  @doc """
  Fetch detailed information about a skill from GitHub without installing it.

  The `repo_spec` can be:
  - `"owner/repo"` — looks for SKILL.md at root
  - `"owner/repo/path/to/skill"` — skill in a subdirectory

  Returns skill metadata (name, description, license, compatibility), full
  instructions, GitHub repo stats (stars, description, last push date, license,
  language), and the skills.sh audit URL.

  Options:
  - `:get_secret` — callback for GitHub API authentication
  - Other options forwarded to `Req` for testing.
  """
  @spec info(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def info(repo_spec, opts \\ []) do
    token = github_token(opts)
    headers = github_headers(token)

    req_opts =
      Keyword.merge([headers: headers, receive_timeout: @timeout], drop_custom_opts(opts))

    with {:ok, owner, repo, path} <- parse_repo_spec(repo_spec),
         {:ok, resolved_path} <- resolve_skill_path(owner, repo, path, req_opts),
         contents_url =
           "#{@github_api}/repos/#{owner}/#{repo}/contents/#{resolved_path}/SKILL.md",
         {:ok, skill_md_content} <- fetch_file_content(contents_url, req_opts),
         {:ok, parsed} <- Parser.parse(skill_md_content),
         {:ok, repo_meta} <- fetch_repo_metadata(owner, repo, req_opts) do
      skill_name = parsed.meta.name

      skills_sh_url =
        if resolved_path == "" do
          "https://skills.sh/#{owner}/#{repo}"
        else
          "https://skills.sh/#{owner}/#{repo}/#{skill_name}"
        end

      {:ok,
       %{
         name: skill_name,
         description: parsed.meta.description,
         license: parsed.meta.license,
         compatibility: parsed.meta.compatibility,
         metadata: parsed.meta.metadata,
         instructions: parsed.body,
         repo: %{
           full_name: "#{owner}/#{repo}",
           stars: repo_meta.stars,
           description: repo_meta.description,
           language: repo_meta.language,
           license: repo_meta.license,
           pushed_at: repo_meta.pushed_at,
           html_url: "https://github.com/#{owner}/#{repo}"
         },
         skills_sh_url: skills_sh_url,
         install_path: repo_spec
       }}
    end
  end

  @doc """
  Install a skill from a GitHub repository into the workspace.

  The `repo_spec` can be:
  - `"owner/repo"` — installs from repo root (expects SKILL.md at root)
  - `"owner/repo/path/to/skill"` — installs from a subdirectory

  Options:
  - `:storage` — a `%Storage.Context{}`
  - `:get_secret` — callback for GitHub API authentication
  - Other options forwarded to `Req` for testing.
  """
  @spec install(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def install(workspace_root, repo_spec, opts \\ []) do
    with {:ok, owner, repo, path} <- parse_repo_spec(repo_spec),
         {:ok, result} <- install_from_github(workspace_root, owner, repo, path, opts) do
      update_capabilities_md(workspace_root, :install, result, opts)
      {:ok, result}
    end
  end

  @doc """
  Analyze a skill's model tier requirements.

  If the skill already has `model_tier` in frontmatter, returns that.
  Otherwise runs static analysis and returns the recommended tier with reasons.

  Options:
  - `:storage` — a `%Storage.Context{}`
  """
  @spec analyze_model_tier(String.t(), String.t(), keyword()) ::
          {:ok, %{tier: atom(), reasons: [String.t()]}} | {:error, String.t()}
  def analyze_model_tier(workspace_root, skill_name, opts \\ []) do
    case read(workspace_root, skill_name, opts) do
      {:ok, parsed} ->
        {tier, reasons} = Analyzer.analyze_with_reasons(parsed)
        {:ok, %{tier: tier, reasons: reasons}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: validation ---

  defp validate_skill_name(name) do
    cond do
      String.contains?(name, "/") ->
        {:error, "Skill name cannot contain path separators"}

      String.contains?(name, "..") ->
        {:error, "Skill name cannot contain '..'"}

      String.trim(name) == "" ->
        {:error, "Skill name cannot be blank"}

      not Regex.match?(~r/^[a-z0-9][a-z0-9\-]*[a-z0-9]$|^[a-z0-9]$/, name) ->
        {:error, "Skill name must be lowercase alphanumeric with hyphens"}

      true ->
        :ok
    end
  end

  defp parse_repo_spec(spec) do
    parts = String.split(spec, "/")

    case parts do
      [owner, repo] ->
        {:ok, owner, repo, ""}

      [owner, repo | rest] ->
        {:ok, owner, repo, Enum.join(rest, "/")}

      _ ->
        {:error, "Invalid repo spec '#{spec}'. Expected 'owner/repo' or 'owner/repo/path'."}
    end
  end

  # --- Private: custom opts handling ---

  @custom_opts [:get_secret, :storage]

  defp drop_custom_opts(opts) do
    Keyword.drop(opts, @custom_opts)
  end

  # --- Private: Skills CLI search ---

  defp search_skills_cli(query) do
    case find_bun() do
      nil ->
        Logger.debug("Skills CLI: bun not found in PATH or known paths")
        {:error, :cli_unavailable}

      bun_path ->
        Logger.debug("Skills CLI: using bun at #{bun_path}")

        case System.cmd(bun_path, ["x", "skills", "find", query],
               stderr_to_stdout: true,
               env: [{"NO_COLOR", "1"}, {"PATH", build_path()}]
             ) do
          {output, 0} ->
            {:ok, parse_skills_cli_output(output)}

          {output, code} ->
            Logger.warning("Skills CLI failed (exit #{code}): #{String.slice(output, 0, 200)}")
            {:error, :cli_unavailable}
        end
    end
  rescue
    e ->
      Logger.warning("Skills CLI error: #{inspect(e)}")
      {:error, :cli_unavailable}
  end

  @bun_known_paths ["/usr/local/bin/bun", "/usr/bin/bun"]

  defp find_bun do
    System.find_executable("bun") || Enum.find(@bun_known_paths, &File.exists?/1)
  end

  defp build_path do
    system_path = System.get_env("PATH") || ""
    extra = ["/usr/local/bin", "/usr/bin", "/bin"]
    Enum.join([system_path | extra], ":")
  end

  defp parse_skills_cli_output(output) do
    # Strip ANSI escape codes
    clean = Regex.replace(~r/\e\[[0-9;]*m/, output, "")

    # Match lines like: owner/repo@skill-name  N installs
    # Followed by: └ https://skills.sh/owner/repo/skill-name
    ~r/^([^\s@]+)@([^\s]+)\s+(\d+)\s+installs\s*\n[^\n]*└\s*(https?:\/\/\S+)/m
    |> Regex.scan(clean)
    |> Enum.map(fn [_, repo, skill_name, installs, url] ->
      %{
        name: skill_name,
        repo: repo,
        install_path: "#{repo}/#{skill_name}",
        installs: String.to_integer(installs),
        html_url: url,
        source: "skills.sh"
      }
    end)
  end

  # --- Private: GitHub search ---

  defp search_github(query, token, opts) do
    search_query = URI.encode("#{query} filename:SKILL.md")
    url = "#{@github_api}/search/code?q=#{search_query}&per_page=20"

    headers = github_headers(token)

    req_opts =
      Keyword.merge([headers: headers, receive_timeout: @timeout], drop_custom_opts(opts))

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        results =
          items
          |> Enum.filter(fn item -> item["name"] == "SKILL.md" end)
          |> Enum.map(fn item ->
            repo = item["repository"]

            %{
              name: extract_skill_name_from_path(item["path"]),
              repo: repo["full_name"],
              path: Path.dirname(item["path"]),
              html_url: item["html_url"],
              source: "github"
            }
          end)
          |> Enum.uniq_by(& &1.repo)

        {:ok, results}

      {:ok, %{status: 403}} ->
        {:error, "GitHub API rate limited. Try again later."}

      {:ok, %{status: 401}} ->
        {:error, "Invalid GitHub token."}

      {:ok, %{status: status, body: body}} ->
        {:error, "GitHub search failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "GitHub search request failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Search error: #{Exception.message(e)}"}
  end

  defp extract_skill_name_from_path(path) do
    dir = Path.dirname(path)
    if dir == ".", do: "(root)", else: Path.basename(dir)
  end

  # --- Private: GitHub install ---

  defp install_from_github(workspace_root, owner, repo, path, opts) do
    {ctx, rest_opts} = extract_storage_and_req_opts(workspace_root, opts)
    token = github_token(opts)
    headers = github_headers(token)

    req_opts =
      Keyword.merge([headers: headers, receive_timeout: @timeout], drop_custom_opts(rest_opts))

    # Resolve the actual path to SKILL.md within the repo.
    # Skills registries (skills.sh) often nest skills in subdirectories
    # like dist/skills/<name>/ or packages/skills/<name>/.
    with {:ok, resolved_path} <- resolve_skill_path(owner, repo, path, req_opts),
         contents_url =
           "#{@github_api}/repos/#{owner}/#{repo}/contents/#{resolved_path}/SKILL.md",
         {:ok, skill_md_content} <- fetch_file_content(contents_url, req_opts),
         {:ok, parsed} <- Parser.parse(skill_md_content),
         :ok <- validate_skill_name(parsed.meta.name) do
      skill_name = parsed.meta.name

      # Analyze and inject model_tier if not already set
      skill_md_content = ensure_model_tier(skill_md_content, parsed)

      # Inject source repo for cross-workspace skill sharing
      install_path =
        if path == "" or resolved_path == "",
          do: "#{owner}/#{repo}",
          else: "#{owner}/#{repo}/#{path}"

      skill_md_content = inject_source(skill_md_content, install_path)

      target_rel = "#{@skills_dir}/#{skill_name}"

      Context.mkdir_p(ctx, target_rel)
      Context.write(ctx, "#{target_rel}/SKILL.md", skill_md_content)

      # Fetch directory listing for additional files (scripts/, references/, assets/)
      dir_url = "#{@github_api}/repos/#{owner}/#{repo}/contents/#{resolved_path}"
      file_count = download_directory_contents(ctx, dir_url, target_rel, req_opts, 1)

      Logger.info("Installed skill '#{skill_name}' from #{owner}/#{repo} (#{file_count} files)")

      {:ok,
       %{
         name: skill_name,
         description: parsed.meta.description,
         files: file_count,
         source: "#{owner}/#{repo}"
       }}
    end
  end

  # Try the given path first; if 404, search the repo tree for the skill.
  defp resolve_skill_path(owner, repo, path, req_opts) do
    skill_md_path = if path == "", do: "SKILL.md", else: "#{path}/SKILL.md"
    direct_url = "#{@github_api}/repos/#{owner}/#{repo}/contents/#{skill_md_path}"

    case Req.get(direct_url, req_opts) do
      {:ok, %{status: 200}} ->
        {:ok, if(path == "", do: "", else: path)}

      _ ->
        # Direct path failed — search the repo tree for <skill-name>/SKILL.md
        skill_name = if path == "", do: nil, else: Path.basename(path)
        search_repo_tree(owner, repo, skill_name, req_opts)
    end
  end

  defp search_repo_tree(_owner, _repo, nil, _req_opts),
    do: {:error, "SKILL.md not found at repo root"}

  defp search_repo_tree(owner, repo, skill_name, req_opts) do
    tree_url = "#{@github_api}/repos/#{owner}/#{repo}/git/trees/main?recursive=1"

    case Req.get(tree_url, req_opts) do
      {:ok, %{status: 200, body: %{"tree" => tree}}} ->
        suffix = "#{skill_name}/SKILL.md"

        case Enum.find(tree, fn item ->
               item["type"] == "blob" && String.ends_with?(item["path"], suffix)
             end) do
          %{"path" => found_path} ->
            # Return the directory containing SKILL.md
            {:ok, Path.dirname(found_path)}

          nil ->
            {:error, "Skill '#{skill_name}' not found in #{owner}/#{repo}"}
        end

      {:ok, %{status: status}} ->
        {:error, "Failed to search repo tree (#{status})"}

      {:error, reason} ->
        {:error, "Failed to search repo tree: #{inspect(reason)}"}
    end
  end

  defp extract_storage_and_req_opts(workspace_root, opts) do
    {storage, rest} = Keyword.pop(opts, :storage)
    ctx = storage || Context.for_workspace(workspace_root)
    {ctx, rest}
  end

  defp fetch_file_content(url, req_opts) do
    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: %{"content" => content, "encoding" => "base64", "size" => size}}}
      when size <= @max_file_size ->
        {:ok, Base.decode64!(String.replace(content, "\n", ""))}

      {:ok, %{status: 200, body: %{"size" => size}}} when size > @max_file_size ->
        {:error, "File exceeds #{div(@max_file_size, 1024)}KB size limit"}

      {:ok, %{status: 200, body: %{"download_url" => download_url}}}
      when is_binary(download_url) ->
        # Fallback: use download_url for files not returned inline
        case Req.get(download_url, req_opts) do
          {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
          _ -> {:error, "Failed to download file from #{download_url}"}
        end

      {:ok, %{status: 404}} ->
        {:error, "Not found: #{url}"}

      {:ok, %{status: status}} ->
        {:error, "GitHub API error (#{status})"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp download_directory_contents(ctx, url, target_rel, req_opts, file_count) do
    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: items}} when is_list(items) ->
        Enum.reduce(items, file_count, fn item, count ->
          name = item["name"]
          type = item["type"]

          cond do
            name == "SKILL.md" ->
              # Already downloaded
              count

            type == "file" and (item["size"] || 0) <= @max_file_size ->
              case fetch_file_content(item["url"], req_opts) do
                {:ok, content} ->
                  Context.write(ctx, "#{target_rel}/#{name}", content)
                  count + 1

                {:error, _} ->
                  count
              end

            type == "dir" and name in ["scripts", "references", "assets"] ->
              Context.mkdir_p(ctx, "#{target_rel}/#{name}")

              download_directory_contents(
                ctx,
                item["url"],
                "#{target_rel}/#{name}",
                req_opts,
                count
              )

            true ->
              count
          end
        end)

      _ ->
        file_count
    end
  end

  # --- Private: GitHub repo metadata ---

  defp fetch_repo_metadata(owner, repo, req_opts) do
    url = "#{@github_api}/repos/#{owner}/#{repo}"

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} ->
        license_name =
          case body["license"] do
            %{"spdx_id" => id} when is_binary(id) and id != "NOASSERTION" -> id
            %{"name" => name} when is_binary(name) -> name
            _ -> nil
          end

        {:ok,
         %{
           stars: body["stargazers_count"],
           description: body["description"],
           language: body["language"],
           license: license_name,
           pushed_at: body["pushed_at"]
         }}

      {:ok, %{status: 404}} ->
        {:error, "Repository #{owner}/#{repo} not found"}

      {:ok, %{status: 403}} ->
        {:error, "GitHub API rate limited. Try again later."}

      {:ok, %{status: status}} ->
        {:error, "GitHub API error fetching repo metadata (#{status})"}

      {:error, reason} ->
        {:error, "Failed to fetch repo metadata: #{inspect(reason)}"}
    end
  end

  # --- Private: GitHub auth ---

  defp github_token(opts \\ []) do
    get_secret = Keyword.get(opts, :get_secret)

    cond do
      is_function(get_secret, 2) ->
        case get_secret.("github", "api_key") do
          {:ok, token} -> token
          _ -> System.get_env("GITHUB_TOKEN")
        end

      true ->
        System.get_env("GITHUB_TOKEN")
    end
  end

  defp github_headers(nil), do: [{"accept", "application/vnd.github.v3+json"}]

  defp github_headers(token),
    do: [{"accept", "application/vnd.github.v3+json"}, {"authorization", "Bearer #{token}"}]

  # --- Private: model tier injection ---

  defp inject_source(raw_content, install_path) do
    if String.contains?(raw_content, "source:") do
      raw_content
    else
      # Insert source: line before the closing ---
      String.replace(raw_content, ~r/\n---\n/, "\nsource: #{install_path}\n---\n", global: false)
    end
  end

  defp ensure_model_tier(raw_content, parsed) do
    case Analyzer.inject_model_tier(raw_content) do
      {:ok, updated} ->
        if updated != raw_content do
          tier = Analyzer.analyze(parsed)
          Logger.info("Analyzed skill '#{parsed.meta.name}': model_tier=#{tier}")
        end

        updated

      {:error, _} ->
        raw_content
    end
  end

  # --- Private: CAPABILITIES.md auto-update ---

  @capabilities_file "CAPABILITIES.md"
  @skills_header "## Current Skills"

  defp update_capabilities_md(workspace_root, action, data, opts) do
    ctx = Keyword.get(opts, :storage) || Context.for_workspace(workspace_root)

    case action do
      :install ->
        append_skill_to_capabilities(ctx, data.name, data.description)

      :remove ->
        regenerate_capabilities_skills(ctx, workspace_root, opts)
    end
  rescue
    e ->
      Logger.warning("Failed to update CAPABILITIES.md: #{Exception.message(e)}")
      :ok
  end

  defp append_skill_to_capabilities(ctx, name, description) do
    skill_line = "- **#{name}** — #{description}"

    case Context.read(ctx, @capabilities_file) do
      {:ok, content} ->
        updated = insert_after_skills_header(content, skill_line)
        Context.write(ctx, @capabilities_file, updated)

      {:error, _} ->
        # File doesn't exist — create with just this skill
        Context.write(ctx, @capabilities_file, """
        # Capabilities

        ## Current Skills

        #{skill_line}

        ## Desired Capabilities

        (Add capabilities you want this workspace to develop.)
        """)
    end
  end

  defp insert_after_skills_header(content, skill_line) do
    lines = String.split(content, "\n")

    {before, after_header} =
      Enum.split_while(lines, fn line ->
        String.trim(line) != @skills_header
      end)

    case after_header do
      [header | rest] ->
        # Find the next section header or end of file
        {section_body, remaining} =
          Enum.split_while(rest, fn line ->
            not (String.starts_with?(String.trim(line), "## ") and
                   String.trim(line) != @skills_header)
          end)

        # Check if skill already listed (avoid duplicates)
        if Enum.any?(section_body, &String.contains?(&1, "**#{extract_skill_name(skill_line)}**")) do
          content
        else
          # Append skill line at end of section body
          new_section = section_body ++ [skill_line]
          Enum.join(before ++ [header | new_section] ++ remaining, "\n")
        end

      [] ->
        # No skills header found — append one
        content <> "\n\n#{@skills_header}\n\n#{skill_line}\n"
    end
  end

  defp extract_skill_name(skill_line) do
    case Regex.run(~r/\*\*(.+?)\*\*/, skill_line) do
      [_, name] -> name
      _ -> ""
    end
  end

  defp regenerate_capabilities_skills(ctx, workspace_root, opts) do
    case list(workspace_root, opts) do
      {:ok, skills} ->
        skill_lines =
          if skills == [] do
            "(No skills currently installed)"
          else
            Enum.map_join(skills, "\n", fn s ->
              "- **#{s.name}** — #{s.description}"
            end)
          end

        case Context.read(ctx, @capabilities_file) do
          {:ok, content} ->
            updated = replace_skills_section(content, skill_lines)
            Context.write(ctx, @capabilities_file, updated)

          {:error, _} ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp replace_skills_section(content, new_skill_lines) do
    lines = String.split(content, "\n")

    {before, after_header} =
      Enum.split_while(lines, fn line ->
        String.trim(line) != @skills_header
      end)

    case after_header do
      [header | rest] ->
        {_old_body, remaining} =
          Enum.split_while(rest, fn line ->
            not (String.starts_with?(String.trim(line), "## ") and
                   String.trim(line) != @skills_header)
          end)

        new_body = [header, "" | String.split(new_skill_lines, "\n")] ++ [""]
        Enum.join(before ++ new_body ++ remaining, "\n")

      [] ->
        content
    end
  end
end
