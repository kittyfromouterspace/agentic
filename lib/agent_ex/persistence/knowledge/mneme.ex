defmodule AgentEx.Persistence.Knowledge.Mneme do
  @moduledoc """
  Mneme-backed knowledge storage backend.

  Delegates to Mneme's Tier 2 API (entries + edges) for hybrid vector + graph
  knowledge search with auto-embedding.

  ## Configuration

  Mneme must be configured with a repo and embedding provider:

      config :mneme,
        repo: Mneme.TestRepo,
        embedding: [provider: Mneme.Embedding.Mock, mock: true]

  ## Opts

  All callbacks accept `opts` with:
  - `:scope_id` — UUID scope for entries
  - `:owner_id` — UUID owner for entries
  """

  @behaviour AgentEx.Persistence.Knowledge

  import Ecto.Query

  @impl true
  def search(query, opts) do
    search_opts =
      []
      |> maybe_put(:scope_id, opts[:scope_id])
      |> maybe_put(:owner_id, opts[:owner_id])
      |> maybe_put(:limit, opts[:limit])

    case Mneme.search(query, search_opts) do
      {:ok, context_pack} ->
        entries =
          (context_pack.entries ++ Map.get(context_pack, :related_entries, []))
          |> Enum.map(&mneme_entry_to_map/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.id)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def create_entry(entry, opts) do
    content = entry[:content] || entry.content

    mneme_opts =
      [
        entry_type: entry[:entry_type] || "note",
        source: entry[:source] || "system"
      ]
      |> maybe_put(:scope_id, entry[:scope_id] || opts[:scope_id])
      |> maybe_put(:owner_id, entry[:owner_id] || opts[:owner_id])
      |> maybe_put(:summary, entry[:summary])
      |> maybe_put(:source_id, entry[:source_id])
      |> maybe_put(:metadata, entry[:metadata])
      |> maybe_put(:confidence, entry[:confidence])

    case Mneme.remember(content, mneme_opts) do
      {:ok, mneme_entry} ->
        {:ok, mneme_entry_to_map(mneme_entry)}

      {:error, changeset} ->
        {:error, format_changeset_error(changeset)}
    end
  end

  @impl true
  def get_entry(entry_id, _opts) do
    repo = Mneme.Config.repo()

    case repo.get(Mneme.Schema.Entry, entry_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, mneme_entry_to_map(entry)}
    end
  end

  @impl true
  def get_edges(entry_id, direction, _opts) do
    repo = Mneme.Config.repo()

    query =
      case direction do
        :from ->
          from(e in Mneme.Schema.Edge, where: e.source_entry_id == ^entry_id)

        :to ->
          from(e in Mneme.Schema.Edge, where: e.target_entry_id == ^entry_id)
      end

    edges = repo.all(query)
    {:ok, Enum.map(edges, &mneme_edge_to_map/1)}
  end

  @impl true
  def create_edge(from_id, to_id, relation, opts) do
    edge_opts =
      []
      |> maybe_put(:weight, opts[:weight])
      |> maybe_put(:metadata, opts[:metadata])

    case Mneme.connect(from_id, to_id, relation, edge_opts) do
      {:ok, edge} ->
        {:ok, mneme_edge_to_map(edge)}

      {:error, changeset} ->
        {:error, format_changeset_error(changeset)}
    end
  end

  @impl true
  def recent(scope_id, opts) do
    limit = opts[:limit] || 20
    entries = Mneme.Knowledge.recent(scope_id, limit: limit)
    {:ok, Enum.map(entries, &mneme_entry_to_map/1)}
  end

  @impl true
  def supersede(scope_id, entity, relation, _new_value) do
    _count = Mneme.Knowledge.supersede(scope_id, entity, relation, "")
    {:ok, []}
  end

  defp mneme_entry_to_map(%Mneme.Schema.Entry{} = entry) do
    %{
      id: entry.id,
      content: entry.content,
      entry_type: entry.entry_type,
      source: entry.source,
      scope_id: entry.scope_id,
      owner_id: entry.owner_id,
      metadata: entry.metadata || %{},
      confidence: entry.confidence,
      inserted_at: entry.inserted_at
    }
  end

  defp mneme_entry_to_map(%{} = entry) do
    %{
      id: entry["id"] || entry[:id],
      content: entry["content"] || entry[:content],
      entry_type: entry["entry_type"] || entry[:entry_type],
      source: entry["source"] || entry[:source],
      scope_id: entry["scope_id"] || entry[:scope_id],
      owner_id: entry["owner_id"] || entry[:owner_id],
      metadata: entry["metadata"] || entry[:metadata] || %{},
      confidence: entry["confidence"] || entry[:confidence],
      inserted_at: entry["inserted_at"] || entry[:inserted_at]
    }
  end

  defp mneme_entry_to_map(_), do: nil

  defp mneme_edge_to_map(%Mneme.Schema.Edge{} = edge) do
    %{
      id: edge.id,
      source_entry_id: edge.source_entry_id,
      target_entry_id: edge.target_entry_id,
      relation: edge.relation,
      weight: edge.weight
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_changeset_error(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    {:validation, errors}
  end
end
