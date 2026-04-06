defmodule AgentEx.Memory.ContextKeeper do
  @moduledoc """
  Per-workspace in-process working memory.

  Maintains two data structures:

  - **facts** — structured triples extracted from tool results and LLM responses
    (entity/relation/value). Capped at 500 entries, oldest dropped first.

  - **working_set** — key-value pairs stored explicitly by the agent or loop stages.
    Supports TTL (seconds or `:infinity`) and priority (`:high`, `:normal`, `:low`).

  Registered via `AgentEx.Memory.ContextKeeperRegistry` so there is at most one keeper
  per workspace. Survives session restarts but stops when the workspace disconnects.
  """

  use GenServer

  require Logger

  @max_facts 500
  @ttl_sweep_interval_ms 60_000
  @high_confidence_threshold 0.8

  # ── Types ────────────────────────────────────────────────────────────

  @type fact :: %{
          entity: String.t(),
          relation: String.t(),
          value: String.t(),
          confidence: float(),
          source_turn: integer(),
          inserted_at: DateTime.t()
        }

  @type working_entry :: %{
          value: term(),
          ttl: integer() | :infinity,
          priority: :high | :normal | :low,
          inserted_at: DateTime.t()
        }

  @type state :: %{
          workspace_id: String.t(),
          facts: [fact()],
          working_set: %{String.t() => working_entry()}
        }

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(workspace_id))
  end

  @doc "Check if a ContextKeeper is running for the given workspace."
  @spec running?(String.t()) :: boolean()
  def running?(workspace_id) do
    case Registry.lookup(AgentEx.Memory.ContextKeeperRegistry, workspace_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @doc "Query facts matching a substring in entity or value fields."
  @spec query(String.t(), String.t()) :: {:ok, [fact()]}
  def query(workspace_id, query_string) do
    GenServer.call(via_tuple(workspace_id), {:query, query_string})
  catch
    :exit, _ -> {:ok, []}
  end

  @doc "Ingest a list of facts from FactExtractor."
  @spec ingest(String.t(), [fact()]) :: :ok
  def ingest(_workspace_id, []), do: :ok

  def ingest(workspace_id, facts) when is_list(facts) do
    GenServer.cast(via_tuple(workspace_id), {:ingest, facts})
  catch
    :exit, _ -> :ok
  end

  @doc "Store a key-value pair in the working set."
  @spec set_working_value(String.t(), String.t(), term(), keyword()) :: :ok
  def set_working_value(workspace_id, key, value, opts \\ []) do
    GenServer.cast(via_tuple(workspace_id), {:set_working_value, key, value, opts})
  catch
    :exit, _ -> :ok
  end

  @doc "Retrieve a value from the working set."
  @spec get_working_value(String.t(), String.t()) :: term() | nil
  def get_working_value(workspace_id, key) do
    GenServer.call(via_tuple(workspace_id), {:get_working_value, key})
  catch
    :exit, _ -> nil
  end

  @doc """
  Return formatted context string for injection into system prompt.

  Includes high-priority working set items and recent facts.
  """
  @spec get_context(String.t()) :: String.t() | nil
  def get_context(workspace_id) do
    GenServer.call(via_tuple(workspace_id), :get_context)
  catch
    :exit, _ -> nil
  end

  # ── Callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    workspace_path = Keyword.get(opts, :workspace_path)
    knowledge_callback = Keyword.get(opts, :knowledge_callback)

    Process.flag(:trap_exit, true)
    schedule_ttl_sweep()

    Logger.debug("ContextKeeper started for workspace #{workspace_id}")

    {:ok,
     %{
       workspace_id: workspace_id,
       workspace_path: workspace_path,
       knowledge_callback: knowledge_callback,
       facts: [],
       working_set: %{}
     }}
  end

  @impl true
  def handle_call({:query, query_string}, _from, state) do
    downcased = String.downcase(query_string)

    matching =
      Enum.filter(state.facts, fn fact ->
        String.contains?(String.downcase(fact.entity), downcased) or
          String.contains?(String.downcase(fact.value), downcased)
      end)

    {:reply, {:ok, matching}, state}
  end

  def handle_call({:get_working_value, key}, _from, state) do
    case Map.get(state.working_set, key) do
      nil -> {:reply, nil, state}
      entry -> {:reply, entry.value, state}
    end
  end

  def handle_call(:get_context, _from, state) do
    context = format_context(state)
    {:reply, context, state}
  end

  @impl true
  def handle_cast({:ingest, new_facts}, state) do
    now = DateTime.utc_now()

    stamped =
      Enum.map(new_facts, fn fact ->
        Map.put_new(fact, :inserted_at, now)
      end)

    # Handle supersession: if a fact has :supersedes, demote matching old facts
    existing = apply_supersessions(state.facts, stamped)

    combined = existing ++ stamped

    # Cap at @max_facts, drop oldest
    trimmed =
      if length(combined) > @max_facts do
        Enum.take(combined, -@max_facts)
      else
        combined
      end

    {:noreply, %{state | facts: trimmed}}
  end

  def handle_cast({:set_working_value, key, value, opts}, state) do
    entry = %{
      value: value,
      ttl: Keyword.get(opts, :ttl, :infinity),
      priority: Keyword.get(opts, :priority, :normal),
      inserted_at: DateTime.utc_now()
    }

    {:noreply, %{state | working_set: Map.put(state.working_set, key, entry)}}
  end

  @impl true
  def handle_info(:ttl_sweep, state) do
    now = DateTime.utc_now()

    swept =
      Map.filter(state.working_set, fn {_key, entry} ->
        case entry.ttl do
          :infinity ->
            true

          ttl_seconds when is_integer(ttl_seconds) ->
            elapsed = DateTime.diff(now, entry.inserted_at, :second)
            elapsed < ttl_seconds
        end
      end)

    schedule_ttl_sweep()
    {:noreply, %{state | working_set: swept}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush_to_memory_md(state)
    flush_to_knowledge_store(state)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp via_tuple(workspace_id) do
    {:via, Registry, {AgentEx.Memory.ContextKeeperRegistry, workspace_id}}
  end

  defp schedule_ttl_sweep do
    Process.send_after(self(), :ttl_sweep, @ttl_sweep_interval_ms)
  end

  defp format_context(state) do
    working_lines = format_working_set(state.working_set)
    fact_lines = format_recent_facts(state.facts)

    parts =
      Enum.reject([working_lines, fact_lines], &is_nil/1)

    case parts do
      [] -> nil
      items -> Enum.join(items, "\n\n")
    end
  end

  defp format_working_set(working_set) when map_size(working_set) == 0, do: nil

  defp format_working_set(working_set) do
    # Show high-priority first, then normal
    entries =
      working_set
      |> Enum.sort_by(fn {_k, v} -> priority_rank(v.priority) end)
      |> Enum.map(fn {key, entry} ->
        "- #{key}: #{inspect(entry.value)}"
      end)

    if entries == [] do
      nil
    else
      "[Working Memory]\n" <> Enum.join(entries, "\n")
    end
  end

  defp format_recent_facts([]), do: nil

  defp format_recent_facts(facts) do
    # Show the 20 most recent facts
    recent =
      facts
      |> Enum.take(-20)
      |> Enum.map(fn fact ->
        "- #{fact.entity} #{fact.relation} #{fact.value}"
      end)

    if recent == [] do
      nil
    else
      "[Recent Facts]\n" <> Enum.join(recent, "\n")
    end
  end

  defp priority_rank(:high), do: 0
  defp priority_rank(:normal), do: 1
  defp priority_rank(:low), do: 2

  defp apply_supersessions(existing_facts, new_facts) do
    # Find new facts that declare supersession
    superseding =
      Enum.filter(new_facts, &Map.has_key?(&1, :supersedes))

    if superseding == [] do
      existing_facts
    else
      Enum.map(existing_facts, fn fact ->
        if superseded_by?(fact, superseding) do
          %{fact | confidence: 0.1}
        else
          fact
        end
      end)
    end
  end

  defp superseded_by?(fact, superseding_facts) do
    Enum.any?(superseding_facts, fn new_fact ->
      # Match by entity + relation
      String.downcase(to_string(fact.entity)) == String.downcase(to_string(new_fact.entity)) and
        String.downcase(to_string(fact.relation)) == String.downcase(to_string(new_fact.relation))
    end)
  end

  # ── Memory persistence ─────────────────────────────────────────────

  @memory_md_max_chars 4_000
  @max_auto_sections 2

  defp flush_to_memory_md(%{workspace_path: nil}), do: :ok
  defp flush_to_memory_md(%{facts: [], working_set: ws}) when map_size(ws) == 0, do: :ok

  defp flush_to_memory_md(state) do
    lines = collect_persistent_entries(state)

    if lines != [] do
      new_section =
        "\n\n## Session Notes (auto-saved)\n" <>
          Enum.join(lines, "\n") <> "\n"

      storage = AgentEx.Storage.Context.for_workspace(state.workspace_path)

      case AgentEx.Storage.Context.read(storage, "MEMORY.md") do
        {:ok, existing} ->
          updated = prune_and_append(existing, new_section)
          AgentEx.Storage.Context.write(storage, "MEMORY.md", updated)

        {:error, _} ->
          AgentEx.Storage.Context.write(storage, "MEMORY.md", "# Memory\n" <> new_section)
      end

      Logger.debug(
        "ContextKeeper: flushed #{length(lines)} entries to MEMORY.md for #{state.workspace_id}"
      )
    end
  rescue
    e ->
      Logger.warning(
        "ContextKeeper: failed to flush MEMORY.md for #{state.workspace_id}: #{Exception.message(e)}"
      )
  end

  defp prune_and_append(existing, new_section) do
    # Split into human-authored content and auto-saved sections
    {human_content, auto_sections} = split_auto_sections(existing)

    # Keep only the most recent N auto-saved sections + new one
    kept_sections = Enum.take(auto_sections ++ [new_section], -@max_auto_sections)

    result = human_content <> Enum.join(kept_sections)

    # If still over budget, drop oldest auto sections
    if String.length(result) > @memory_md_max_chars and length(kept_sections) > 1 do
      human_content <> List.last(kept_sections)
    else
      result
    end
  end

  defp split_auto_sections(content) do
    # Split on "## Session Notes (auto-saved)" boundaries
    parts = String.split(content, ~r/(?=\n\n## Session Notes \(auto-saved\))/)

    case parts do
      [human | auto] -> {human, auto}
      _ -> {content, []}
    end
  end

  defp collect_persistent_entries(state) do
    # High-confidence facts
    high_facts =
      state.facts
      |> Enum.filter(&(&1.confidence >= @high_confidence_threshold))
      |> Enum.take(-20)
      |> Enum.map(fn f -> "- #{f.entity} #{f.relation} #{f.value}" end)

    # High-priority working set entries
    high_working =
      state.working_set
      |> Enum.filter(fn {_k, v} -> v.priority == :high end)
      |> Enum.map(fn {key, entry} -> "- #{key}: #{inspect(entry.value)}" end)

    high_working ++ high_facts
  end

  # ── Knowledge store persistence ──────────────────────────────────

  defp flush_to_knowledge_store(%{knowledge_callback: nil}), do: :ok
  defp flush_to_knowledge_store(%{workspace_id: nil}), do: :ok
  defp flush_to_knowledge_store(%{facts: [], working_set: ws}) when map_size(ws) == 0, do: :ok

  defp flush_to_knowledge_store(state) do
    if state.knowledge_callback do
      lines = collect_persistent_entries(state)

      if lines != [] do
        content =
          "[Session Working Memory Snapshot]\n" <>
            Enum.join(lines, "\n")

        params = %{
          content: content,
          entry_type: :session_summary,
          source: :system,
          workspace_id: state.workspace_id,
          summary: "Working memory snapshot: #{length(lines)} entries",
          metadata: %{}
        }

        case state.knowledge_callback.(content, params) do
          {:ok, _} ->
            Logger.debug(
              "ContextKeeper: flushed #{length(lines)} entries to Knowledge store for #{state.workspace_id}"
            )

          {:error, reason} ->
            Logger.debug("ContextKeeper: failed to flush to Knowledge store: #{inspect(reason)}")
        end
      end
    end
  rescue
    e ->
      Logger.warning(
        "ContextKeeper: Knowledge store flush error for #{state.workspace_id}: #{Exception.message(e)}"
      )
  end
end
