defmodule AgentEx.Tools.Memory do
  @moduledoc """
  Memory tools for the agent: query knowledge store, write entries,
  and use in-process working memory (ContextKeeper).

  Uses callbacks on ctx for knowledge store operations:
  - `ctx.callbacks[:knowledge_search]` - `(query, opts) -> {:ok, entries} | {:error, term}`
  - `ctx.callbacks[:knowledge_create]` - `(params) -> {:ok, entry} | {:error, term}`
  - `ctx.callbacks[:knowledge_recent]` - `(scope_id) -> {:ok, entries} | {:error, term}`
  """

  alias AgentEx.Memory.ContextKeeper

  def definitions do
    [
      %{
        "name" => "memory_query",
        "description" =>
          "Search the knowledge store for context related to this workspace. " <>
            "Pass a query to find specific memories, or omit for recent workspace context.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" =>
                "Search query to find relevant memories. If omitted, returns recent entries."
            },
            "entry_type" => %{
              "type" => "string",
              "description" => "Filter by entry type",
              "enum" => [
                "outcome",
                "event",
                "decision",
                "observation",
                "hypothesis",
                "note",
                "session_summary",
                "conversation_turn"
              ]
            }
          }
        }
      },
      %{
        "name" => "memory_write",
        "description" =>
          "Persist content to the knowledge store for this workspace. " <>
            "Use for storing important context, decisions, or findings.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "Content to persist"},
            "entry_type" => %{
              "type" => "string",
              "description" => "Type of entry (default: note)",
              "enum" => [
                "outcome",
                "event",
                "decision",
                "observation",
                "hypothesis",
                "note",
                "session_summary"
              ]
            },
            "summary" => %{"type" => "string", "description" => "Optional short summary"}
          },
          "required" => ["content"]
        }
      },
      %{
        "name" => "memory_note",
        "description" =>
          "Store a key-value pair in fast in-process working memory. " <>
            "Persists across turns within this session. Optional TTL in seconds.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "key" => %{
              "type" => "string",
              "description" => "Short identifier (e.g., 'current_task')"
            },
            "value" => %{"type" => "string", "description" => "The content to remember"},
            "ttl" => %{
              "type" => "integer",
              "description" => "Time-to-live in seconds. Omit for permanent."
            },
            "priority" => %{
              "type" => "string",
              "enum" => ["high", "normal", "low"],
              "description" => "Priority level. Default: normal."
            }
          },
          "required" => ["key", "value"]
        }
      },
      %{
        "name" => "memory_recall",
        "description" =>
          "Search in-process working memory for facts and notes matching a query. " <>
            "Faster than memory_query (no external service).",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query for working memory"}
          },
          "required" => ["query"]
        }
      }
    ]
  end

  def execute("memory_query", input, ctx) do
    query = input["query"]
    entry_type = input["entry_type"]
    workspace_id = ctx.metadata[:workspace_id]

    result =
      if query && query != "" do
        if search = ctx.callbacks[:knowledge_search] do
          search.(query, workspace_id: workspace_id, user_id: ctx.user_id)
        else
          {:ok, []}
        end
      else
        if recent = ctx.callbacks[:knowledge_recent] do
          recent.(workspace_id)
        else
          {:ok, []}
        end
      end

    case result do
      {:ok, entries} when is_list(entries) ->
        filtered =
          if entry_type do
            Enum.filter(entries, fn e ->
              type = Map.get(e, :entry_type) || e["entry_type"]
              to_string(type) == entry_type
            end)
          else
            entries
          end

        {:ok, format_entries(filtered)}

      {:ok, entries} ->
        {:ok, Jason.encode!(entries)}

      {:error, reason} ->
        {:ok, "Memory query failed (non-fatal): #{inspect(reason)}"}
    end
  rescue
    e -> {:ok, "Memory query error (non-fatal): #{Exception.message(e)}"}
  end

  def execute("memory_write", %{"content" => content} = input, ctx) do
    workspace_id = ctx.metadata[:workspace_id]
    entry_type = input["entry_type"] || "note"

    params = %{
      content: content,
      entry_type: String.to_existing_atom(entry_type),
      source: :agent,
      workspace_id: workspace_id,
      user_id: ctx.user_id,
      summary: input["summary"],
      metadata: %{}
    }

    if create = ctx.callbacks[:knowledge_create] do
      case create.(params) do
        {:ok, _entry} -> {:ok, "Memory entry created successfully (#{entry_type})"}
        {:error, reason} -> {:ok, "Memory write failed (non-fatal): #{inspect(reason)}"}
      end
    else
      {:ok, "Knowledge store not configured. Entry not persisted."}
    end
  rescue
    e -> {:ok, "Memory write error (non-fatal): #{Exception.message(e)}"}
  end

  def execute("memory_note", input, ctx) do
    key = input["key"]
    value = input["value"]
    workspace_id = ctx.metadata[:workspace_id]

    if workspace_id && ContextKeeper.running?(workspace_id) do
      opts = []

      opts =
        case input["ttl"] do
          nil -> opts
          ttl when is_integer(ttl) -> Keyword.put(opts, :ttl, ttl)
          _ -> opts
        end

      opts =
        case input["priority"] do
          "high" -> Keyword.put(opts, :priority, :high)
          "low" -> Keyword.put(opts, :priority, :low)
          _ -> Keyword.put(opts, :priority, :normal)
        end

      ContextKeeper.set_working_value(workspace_id, key, value, opts)
      {:ok, "Stored '#{key}' in working memory."}
    else
      {:ok, "Working memory not available. Note not stored."}
    end
  end

  def execute("memory_recall", %{"query" => query}, ctx) do
    workspace_id = ctx.metadata[:workspace_id]

    if workspace_id && ContextKeeper.running?(workspace_id) do
      case ContextKeeper.query(workspace_id, query) do
        {:ok, []} ->
          case ContextKeeper.get_context(workspace_id) do
            nil -> {:ok, "No matching facts or notes found for: #{query}"}
            context -> {:ok, context}
          end

        {:ok, facts} ->
          formatted =
            Enum.map_join(facts, "\n", fn fact ->
              "- [turn #{fact.source_turn}] #{fact.entity} #{fact.relation} #{fact.value} (confidence: #{fact.confidence})"
            end)

          case ContextKeeper.get_context(workspace_id) do
            nil -> {:ok, formatted}
            context -> {:ok, context <> "\n\n[Query Results]\n" <> formatted}
          end
      end
    else
      {:ok, "Working memory not available."}
    end
  end

  def execute(_, _, _), do: :not_handled

  defp format_entries([]), do: "No knowledge entries found."

  defp format_entries(entries) when is_list(entries) do
    Enum.map_join(entries, "\n\n---\n\n", fn entry ->
      type = entry["entry_type"] || Map.get(entry, :entry_type, "note")
      content = entry["content"] || Map.get(entry, :content, "")
      summary = entry["summary"] || Map.get(entry, :summary)
      ts = entry["inserted_at"] || Map.get(entry, :inserted_at)

      header = "[#{type}]"
      header = if ts, do: "#{header} #{ts}", else: header
      body = if summary, do: "#{summary}\n#{content}", else: content
      "#{header}\n#{body}"
    end)
  end

  defp format_entries(other), do: inspect(other)
end
