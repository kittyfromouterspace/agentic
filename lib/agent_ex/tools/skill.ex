defmodule AgentEx.Tools.Skill do
  @moduledoc """
  Skill management tools for the agent: list, read, search, install, remove, analyze.
  """

  alias AgentEx.Skill.Service

  def definitions do
    [
      %{
        "name" => "skill_list",
        "description" =>
          "List all skills installed in the workspace with their names and descriptions.",
        "input_schema" => %{"type" => "object", "properties" => %{}, "required" => []}
      },
      %{
        "name" => "skill_read",
        "description" =>
          "Read the full SKILL.md instructions for an installed skill. " <>
            "Use this to load detailed instructions on demand.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "skill_name" => %{"type" => "string", "description" => "Name of the installed skill"}
          },
          "required" => ["skill_name"]
        }
      },
      %{
        "name" => "skill_search",
        "description" =>
          "Search for available skills from public registries. Returns skills with install paths.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Search query (e.g. 'elixir', 'python testing')"
            }
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "skill_info",
        "description" =>
          "Fetch detailed information about a skill from GitHub before installing it.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "repo" => %{
              "type" => "string",
              "description" => "GitHub repo path, e.g. 'owner/repo/skill-name'"
            }
          },
          "required" => ["repo"]
        }
      },
      %{
        "name" => "skill_install",
        "description" => "Install a skill from a GitHub repository into the workspace.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "repo" => %{
              "type" => "string",
              "description" => "GitHub repo path (e.g. owner/repo/skill-name)"
            }
          },
          "required" => ["repo"]
        }
      },
      %{
        "name" => "skill_remove",
        "description" => "Remove an installed skill from the workspace.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "skill_name" => %{"type" => "string", "description" => "Name of the skill to remove"}
          },
          "required" => ["skill_name"]
        }
      },
      %{
        "name" => "skill_analyze",
        "description" => "Analyze an installed skill to determine its model tier requirements.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "skill_name" => %{"type" => "string", "description" => "Name of the skill to analyze"}
          },
          "required" => ["skill_name"]
        }
      }
    ]
  end

  def execute("skill_list", _input, ctx) do
    workspace = ctx.metadata[:workspace]
    {:ok, skills} = Service.list(workspace)
    {:ok, Jason.encode!(skills)}
  end

  def execute("skill_read", %{"skill_name" => name}, ctx) do
    workspace = ctx.metadata[:workspace]

    case Service.read(workspace, name) do
      {:ok, parsed} ->
        {:ok,
         Jason.encode!(%{
           name: parsed.meta.name,
           description: parsed.meta.description,
           instructions: parsed.body
         })}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  def execute("skill_search", %{"query" => query}, _ctx) do
    case Service.search(query) do
      {:ok, results} -> {:ok, Jason.encode!(results)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def execute("skill_info", %{"repo" => repo}, _ctx) do
    case Service.info(repo) do
      {:ok, info} -> {:ok, Jason.encode!(info)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def execute("skill_install", %{"repo" => repo}, ctx) do
    workspace = ctx.metadata[:workspace]

    case Service.install(workspace, repo) do
      {:ok, result} -> {:ok, Jason.encode!(result)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def execute("skill_remove", %{"skill_name" => name}, ctx) do
    workspace = ctx.metadata[:workspace]

    case Service.remove(workspace, name) do
      :ok -> {:ok, "Skill '#{name}' removed."}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def execute("skill_analyze", %{"skill_name" => name}, ctx) do
    workspace = ctx.metadata[:workspace]

    case Service.analyze_model_tier(workspace, name) do
      {:ok, result} -> {:ok, Jason.encode!(result)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def execute(_, _, _), do: :not_handled
end
