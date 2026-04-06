defmodule AgentEx.Tools.Gateway do
  @moduledoc """
  Gateway tools for lazy tool discovery and execution.

  Uses callbacks on ctx for tool gateway operations:
  - `ctx.callbacks[:search_tools]` - `(query, opts) -> [result]`
  - `ctx.callbacks[:get_tool_schema]` - `(name) -> {:ok, schema} | {:error, reason}`
  - `ctx.callbacks[:execute_external_tool]` - `(name, args, ctx) -> {:ok, result} | {:error, reason}`
  """

  alias AgentEx.Tools.Activation

  require Logger

  def definitions do
    [
      %{
        "name" => "search_tools",
        "description" =>
          "Search for available tools by description. Returns compact results with tool name, " <>
            "one-line description, and source. Use this to discover tools before calling them.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "What you're looking for"},
            "category" => %{
              "type" => "string",
              "description" => "Optional filter: 'builtin', 'mcp', 'openapi', 'integration'"
            }
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "use_tool",
        "description" =>
          "Execute a tool from a connected external MCP server or API integration. " <>
            "Use search_tools first to discover the tool name. " <>
            "Do NOT use this for built-in tools (read_file, write_file, bash, etc.).",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "tool_name" => %{"type" => "string", "description" => "The exact tool name"},
            "arguments" => %{"type" => "object", "description" => "Arguments for the tool"}
          },
          "required" => ["tool_name"]
        }
      },
      %{
        "name" => "get_tool_schema",
        "description" => "Get the full input schema for a specific tool.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "tool_name" => %{"type" => "string", "description" => "The exact tool name"}
          },
          "required" => ["tool_name"]
        }
      },
      %{
        "name" => "activate_tool",
        "description" =>
          "Promote an external tool to first-class status so it appears as a direct tool. " <>
            "Budget-limited; LRU tool is auto-deactivated if exceeded.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "tool_name" => %{"type" => "string", "description" => "The tool name to activate"}
          },
          "required" => ["tool_name"]
        }
      },
      %{
        "name" => "deactivate_tool",
        "description" => "Remove an activated tool from your direct tool list to free up budget.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "tool_name" => %{"type" => "string", "description" => "The tool name to deactivate"}
          },
          "required" => ["tool_name"]
        }
      }
    ]
  end

  def execute("search_tools", input, ctx) do
    query = input["query"] || ""
    opts = if input["category"], do: [category: input["category"]], else: []

    if search = ctx.callbacks[:search_tools] do
      results = search.(query, opts)

      if results == [] do
        {:ok, "No tools found matching '#{query}'."}
      else
        {:ok, Jason.encode!(results)}
      end
    else
      {:ok, "Tool search not configured."}
    end
  end

  def execute("activate_tool", input, ctx) do
    tool_name = input["tool_name"]

    case Activation.activate(ctx, tool_name) do
      {:ok, _schema, new_ctx} ->
        status = Activation.budget_status(new_ctx)

        {:ok, "Activated '#{tool_name}'. (#{status.active}/#{status.budget} slots used)", new_ctx}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def execute("deactivate_tool", input, ctx) do
    tool_name = input["tool_name"]
    new_ctx = Activation.deactivate(ctx, tool_name)
    status = Activation.budget_status(new_ctx)

    {:ok, "Deactivated '#{tool_name}'. (#{status.active}/#{status.budget} slots used)", new_ctx}
  end

  def execute("use_tool", input, ctx) do
    tool_name = input["tool_name"]

    tool_args =
      case Map.get(input, "arguments", %{}) do
        args when is_binary(args) ->
          case Jason.decode(args) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        args when is_map(args) ->
          args

        _ ->
          %{}
      end

    if execute_external = ctx.callbacks[:execute_external_tool] do
      case execute_external.(tool_name, tool_args, ctx) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:error, "External tool execution not configured."}
    end
  end

  def execute("get_tool_schema", input, ctx) do
    if get_schema = ctx.callbacks[:get_tool_schema] do
      case get_schema.(input["tool_name"]) do
        {:ok, schema} -> {:ok, Jason.encode!(schema)}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:error, "Tool schema provider not configured."}
    end
  end

  def execute(_, _, _), do: :not_handled
end
