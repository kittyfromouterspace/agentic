defmodule AgentEx.Memory.MemoryManager do
  @moduledoc """
  Retrieves relevant context from the Knowledge store before LLM calls.

  Sits between the agent session and LLM, querying knowledge entries with the
  user's actual prompt to get relevant episodic context. Falls back gracefully
  when knowledge store is unavailable.

  Results are cached briefly to avoid redundant queries for the same prompt.

  ## Knowledge callbacks

  Instead of a hardcoded data access layer, this module accepts optional knowledge
  callbacks via the `:knowledge` option:

  - `:search` — `(query, opts) -> {:ok, entries} | {:error, term}`
  - `:get_edges` — `(id, direction) -> {:ok, edges} | {:error, term}`

  If no knowledge callbacks are provided, only ContextKeeper context is used.
  """

  alias AgentEx.Memory.ContextKeeper

  require Logger

  @cache_ttl_ms 30_000

  @doc """
  Retrieve relevant context from the Knowledge store for a user prompt.

  Queries knowledge entries scoped to the workspace and optionally the user,
  merging results and formatting as a context string.

  Returns `{:ok, context_string}` or `{:ok, nil}` if nothing relevant found.
  Never returns an error — failures are logged and return nil.

  ## Options

  - `:user_id` — user ID for cross-workspace queries
  - `:top_k` — max results (default 10)
  - `:workspace_id` — workspace ID for ContextKeeper lookup
  - `:last_retrieval_at` — timestamp for incremental retrieval
  - `:cached_context` — previously cached context for incremental merge
  - `:knowledge` — map with `:search` and `:get_edges` callback functions
  """
  @spec retrieve_context(String.t(), String.t(), keyword()) :: {:ok, String.t() | nil}
  def retrieve_context(prompt, workspace, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    workspace_id = Keyword.get(opts, :workspace_id)
    last_retrieval_at = Keyword.get(opts, :last_retrieval_at)
    cached_context = Keyword.get(opts, :cached_context)
    knowledge = Keyword.get(opts, :knowledge, %{})
    cache_key = {workspace, user_id, prompt}

    start_time = System.monotonic_time()

    case check_cache(cache_key) do
      {:hit, context} ->
        emit_retrieval_telemetry(
          start_time,
          context,
          workspace_id,
          true,
          last_retrieval_at != nil
        )

        {:ok, context}

      :miss ->
        incremental = last_retrieval_at != nil && cached_context != nil

        # Incremental retrieval: only fetch new entries if we have a previous timestamp
        knowledge_context =
          if incremental do
            do_retrieve_incremental(
              prompt,
              workspace,
              user_id,
              last_retrieval_at,
              cached_context,
              knowledge
            )
          else
            do_retrieve(prompt, workspace, user_id, knowledge)
          end

        keeper_context = retrieve_keeper_context(workspace_id, prompt)
        context = merge_keeper_and_knowledge(keeper_context, knowledge_context)

        put_cache(cache_key, context)
        emit_retrieval_telemetry(start_time, context, workspace_id, false, incremental)
        {:ok, context}
    end
  end

  @doc """
  Format knowledge entries into a context string suitable for system prompt injection.
  """
  @spec format_context(map() | nil) :: String.t() | nil
  def format_context(nil), do: nil
  def format_context(%{memories: []}), do: nil

  def format_context(%{memories: memories}) do
    memories
    |> Enum.filter(&(&1[:content] && &1[:content] != ""))
    |> Enum.map_join("\n\n", fn m -> String.trim(m[:content] || m["content"] || "") end)
    |> case do
      "" -> nil
      text -> text
    end
  end

  def format_context(_), do: nil

  @doc """
  Optimize context by summarizing it if it exceeds the budget.

  Uses a fast LLM call to condense the context while preserving the most
  relevant information for the user's prompt. Only triggers when context
  is significantly over budget (2x+).

  Accepts an optional `llm_chat` function as the 4th argument. If nil, just truncates.

  Returns the original context if it fits, or a summarized version.
  """
  @spec optimize_context(String.t(), String.t() | nil, integer(), function() | nil) ::
          String.t() | nil
  def optimize_context(prompt, context, budget_chars, llm_chat \\ nil)

  def optimize_context(_prompt, nil, _budget_chars, _llm_chat), do: nil
  def optimize_context(_prompt, "", _budget_chars, _llm_chat), do: nil

  def optimize_context(_prompt, context, budget_chars, _llm_chat)
      when byte_size(context) <= budget_chars do
    context
  end

  def optimize_context(prompt, context, budget_chars, nil) do
    # No LLM function provided — just truncate
    if byte_size(context) < budget_chars * 2 do
      String.slice(context, 0, budget_chars)
    else
      String.slice(context, 0, budget_chars)
    end
  end

  def optimize_context(prompt, context, budget_chars, llm_chat) do
    # Only optimize if context is significantly over budget (2x+)
    if byte_size(context) < budget_chars * 2 do
      # Just truncate — not worth an LLM call
      String.slice(context, 0, budget_chars)
    else
      case summarize_with_llm(prompt, context, budget_chars, llm_chat) do
        {:ok, summarized} -> summarized
        {:error, _} -> String.slice(context, 0, budget_chars)
      end
    end
  end

  defp emit_retrieval_telemetry(start_time, context, workspace_id, cache_hit, incremental) do
    duration = System.monotonic_time() - start_time
    context_chars = if is_binary(context), do: String.length(context), else: 0

    :telemetry.execute(
      [:agent_ex, :memory, :retrieval, :stop],
      %{duration: duration, context_chars: context_chars, cache_hit: cache_hit},
      %{workspace_id: workspace_id, incremental: incremental}
    )
  rescue
    _ -> :ok
  end

  # -- Private --

  defp summarize_with_llm(prompt, context, budget_chars, llm_chat) do
    # Estimate target token count from budget
    target_tokens = div(budget_chars, 4)

    summary_prompt = """
    You are a context optimization assistant. The user is about to ask an AI assistant the following question:

    #{String.slice(prompt, 0, 500)}

    Below is retrieved context that may be relevant. Summarize it to fit within approximately #{target_tokens} tokens.
    Keep the most relevant information for answering the user's question. Remove redundant or irrelevant content.
    Output ONLY the summarized context, no preamble.

    Context to summarize:
    #{String.slice(context, 0, 16_000)}
    """

    params = %{
      "messages" => [
        %{
          "role" => "system",
          "content" => "You are a concise context summarizer. Output only the summarized content."
        },
        %{"role" => "user", "content" => summary_prompt}
      ],
      "tools" => [],
      "session_id" => nil,
      "user_id" => nil
    }

    case llm_chat.(params) do
      {:ok, response} ->
        text =
          (response["content"] || [])
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", &(&1["text"] || ""))

        if text == "" do
          {:error, :empty_response}
        else
          {:ok, String.slice(text, 0, budget_chars)}
        end

      {:error, reason} ->
        Logger.debug("MemoryManager: context optimization LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.debug("MemoryManager: context optimization error: #{Exception.message(e)}")
      {:error, e}
  end

  defp do_retrieve_incremental(prompt, workspace, user_id, since, cached, knowledge) do
    search_fn = knowledge[:search]

    if search_fn do
      opts = [workspace_id: workspace, since: since]
      opts = if user_id, do: Keyword.put(opts, :user_id, user_id), else: opts

      case search_fn.(prompt, opts) do
        {:ok, entries} when is_list(entries) and entries != [] ->
          new_context = format_entries(entries)
          merge_keeper_and_knowledge(cached, new_context)

        _ ->
          cached
      end
    else
      cached
    end
  rescue
    _ -> cached
  end

  defp do_retrieve(prompt, workspace, user_id, knowledge) do
    search_fn = knowledge[:search]

    if search_fn do
      opts = [workspace_id: workspace]
      opts = if user_id, do: Keyword.put(opts, :user_id, user_id), else: opts

      case search_fn.(prompt, opts) do
        {:ok, entries} when is_list(entries) and entries != [] ->
          # Follow edges 1 hop from primary results
          entries_with_related = follow_edges(entries, knowledge)
          format_entries(entries_with_related)

        {:ok, _} ->
          nil

        {:error, reason} ->
          Logger.debug("MemoryManager: knowledge search failed: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  rescue
    e ->
      Logger.debug("MemoryManager: retrieval error: #{Exception.message(e)}")
      nil
  end

  defp follow_edges(primary_entries, knowledge) do
    get_edges_fn = knowledge[:get_edges]

    if get_edges_fn do
      primary_ids =
        primary_entries
        |> Enum.map(fn e -> Map.get(e, :id) || e["id"] end)
        |> Enum.reject(&is_nil/1)

      # Follow edges from primary results (1 hop)
      related_ids =
        primary_ids
        |> Enum.flat_map(fn id ->
          case get_edges_fn.(id, :from) do
            {:ok, edges} when is_list(edges) ->
              Enum.map(edges, fn edge ->
                Map.get(edge, :target_entry_id) || edge["target_entry_id"]
              end)

            _ ->
              []
          end
        end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 in primary_ids))
        |> Enum.take(5)

      if related_ids == [] do
        primary_entries
      else
        related_entries = fetch_entries_by_ids(related_ids, knowledge)

        # Mark related entries
        marked = Enum.map(related_entries, &Map.put(&1, :_related, true))
        primary_entries ++ marked
      end
    else
      primary_entries
    end
  rescue
    _ -> primary_entries
  end

  defp fetch_entries_by_ids([], _knowledge), do: []

  defp fetch_entries_by_ids(ids, knowledge) do
    search_fn = knowledge[:search]

    if search_fn do
      # Try batch fetch via search — fall back to individual queries
      Enum.flat_map(ids, fn id ->
        case search_fn.(id, []) do
          {:ok, entries} when is_list(entries) -> Enum.take(entries, 1)
          _ -> []
        end
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp format_entries(entries) do
    # Separate primary results from related (graph-traversed) results
    {primary, related} =
      Enum.split_with(entries, fn e ->
        not Map.get(e, :_related, false)
      end)

    primary_text =
      primary
      |> Enum.map(fn entry ->
        content = Map.get(entry, :content) || entry["content"] || ""
        String.trim(content)
      end)
      |> Enum.filter(&(&1 != ""))
      |> Enum.join("\n\n")

    related_text =
      related
      |> Enum.map(fn entry ->
        content = Map.get(entry, :content) || entry["content"] || ""
        "[Related] " <> String.trim(content)
      end)
      |> Enum.filter(&(&1 != "[Related] "))
      |> Enum.join("\n\n")

    case {primary_text, related_text} do
      {"", ""} -> nil
      {p, ""} -> p
      {"", r} -> r
      {p, r} -> p <> "\n\n" <> r
    end
  end

  # Simple ETS-based cache
  @cache_table :agent_ex_memory_cache

  defp ensure_cache_table do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  defp check_cache(key) do
    ensure_cache_table()

    case :ets.lookup(@cache_table, key) do
      [{^key, context, ts}] ->
        if System.monotonic_time(:millisecond) - ts < @cache_ttl_ms do
          {:hit, context}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp put_cache(key, context) do
    ensure_cache_table()
    :ets.insert(@cache_table, {key, context, System.monotonic_time(:millisecond)})
  rescue
    _ -> :ok
  end

  # ── ContextKeeper integration ──────────────────────────────────────

  defp retrieve_keeper_context(nil, _prompt), do: nil

  defp retrieve_keeper_context(workspace_id, prompt) do
    if ContextKeeper.running?(workspace_id) do
      # Get formatted working memory + recent facts
      general_context = ContextKeeper.get_context(workspace_id)

      # Also query for prompt-specific facts
      query_results =
        case ContextKeeper.query(workspace_id, prompt) do
          {:ok, []} -> nil
          {:ok, facts} -> format_keeper_facts(facts)
        end

      case {general_context, query_results} do
        {nil, nil} -> nil
        {ctx, nil} -> ctx
        {nil, qr} -> qr
        {ctx, qr} -> ctx <> "\n\n" <> qr
      end
    end
  rescue
    _ -> nil
  end

  defp merge_keeper_and_knowledge(nil, nil), do: nil
  defp merge_keeper_and_knowledge(keeper, nil), do: keeper
  defp merge_keeper_and_knowledge(nil, knowledge), do: knowledge
  defp merge_keeper_and_knowledge(keeper, knowledge), do: keeper <> "\n\n" <> knowledge

  defp format_keeper_facts(facts) do
    lines =
      Enum.map(facts, fn fact ->
        "- #{fact.entity} #{fact.relation} #{fact.value}"
      end)

    "[Relevant Working Memory]\n" <> Enum.join(lines, "\n")
  end
end
