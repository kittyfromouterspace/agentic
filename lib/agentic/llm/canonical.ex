defmodule Agentic.LLM.Canonical do
  @moduledoc """
  Canonical model identity. The (provider, model_id) → canonical_id mapping
  used to group pathways for the same underlying model weights across
  providers (e.g. Anthropic direct, Claude Code CLI, OpenRouter all serve
  `claude-sonnet-4`).

  Resolution order for `for_model/2`:

    1. Static overrides (Codex aliases, Claude Code short aliases, z.ai GLM
       family — anything models.dev doesn't list)
    2. The cached models.dev catalog (~50 providers, refreshed every 24h)
    3. Pattern rules (e.g. strip OpenRouter org prefix)
    4. Fallback `"<provider>:<model_id>"` so the model is never canonical-less

  ## Persistence

  The fetched models.dev snapshot is written to `~/.agentic/models_dev.json`
  on every successful refresh so first boot is fast and we degrade cleanly
  when models.dev is unreachable.
  """

  use GenServer

  require Logger

  @models_dev_url "https://models.dev/api.json"
  @refresh_interval_ms 24 * 60 * 60 * 1000
  @initial_refresh_delay_ms 1_000
  @http_timeout_ms 15_000

  # Static overrides — what models.dev doesn't list, or where we want to
  # pin a specific canonical_id regardless of upstream changes.
  @overrides %{
    # Codex uses rolling aliases that aren't in models.dev:
    {:codex, "gpt-5.5"} => "gpt-5.5",
    {:codex, "gpt-5.4"} => "gpt-5.4",
    {:codex, "gpt-5.4-mini"} => "gpt-5.4-mini",
    {:codex, "gpt-5.3-codex"} => "gpt-5.3-codex",
    {:codex, "gpt-5.3-codex-spark"} => "gpt-5.3-codex",
    {:codex, "gpt-5.2"} => "gpt-5.2",

    # Claude Code accepts both short aliases and dated IDs:
    {:claude_code, "sonnet"} => "claude-sonnet-4",
    {:claude_code, "opus"} => "claude-opus-4",
    {:claude_code, "haiku"} => "claude-haiku-4",
    {:claude_code, "claude-sonnet-4"} => "claude-sonnet-4",
    {:claude_code, "claude-opus-4"} => "claude-opus-4",
    {:claude_code, "claude-haiku-4"} => "claude-haiku-4",
    {:claude_code, "claude-sonnet-4-20250514"} => "claude-sonnet-4",
    {:claude_code, "claude-opus-4-20250514"} => "claude-opus-4",
    {:claude_code, "claude-haiku-4-20250414"} => "claude-haiku-4",

    # z.ai GLM family — no /models endpoint, seed from docs.
    {:zai, "glm-4.5"} => "glm-4.5",
    {:zai, "glm-4.5-air"} => "glm-4.5-air",
    {:zai, "glm-4.5-flash"} => "glm-4.5-flash",
    {:zai, "glm-4.5v"} => "glm-4.5v",
    {:zai, "glm-4.6"} => "glm-4.6",
    {:zai, "glm-4.7"} => "glm-4.7",
    {:zai, "glm-4.7-flash"} => "glm-4.7-flash",
    {:zai, "glm-5"} => "glm-5",
    {:zai, "glm-5.1"} => "glm-5.1",
    {:zai, "glm-5-turbo"} => "glm-5-turbo",

    # Gemini CLI — Google models served via the gemini binary.
    {:gemini, "google/gemini-3-pro"} => "gemini-3-pro",
    {:gemini, "google/gemini-3-flash"} => "gemini-3-flash",

    # Kimi Code — Moonshot K2 family.
    {:kimi, "moonshot/k2"} => "moonshot-k2",
    {:kimi, "moonshot/k2-thinking"} => "moonshot-k2-thinking",

    # Qwen Code — Alibaba Qwen family.
    {:qwen, "alibaba/qwen3-coder"} => "qwen3-coder",
    {:qwen, "alibaba/qwen3-max"} => "qwen3-max",

    # Anthropic direct: pin family canonicals so dated IDs collapse.
    {:anthropic, "claude-sonnet-4-20250514"} => "claude-sonnet-4",
    {:anthropic, "claude-opus-4-20250514"} => "claude-opus-4",
    {:anthropic, "claude-haiku-4-20250414"} => "claude-haiku-4"
  }

  # Pattern rules run after static + models.dev miss. They handle providers
  # whose IDs already encode the canonical via convention.
  @pattern_rules [
    # OpenRouter: "anthropic/claude-sonnet-4" → "claude-sonnet-4"
    {:openrouter, &__MODULE__.strip_org_prefix/1},
    # OpenCode: "anthropic/claude-sonnet-4-5" → "claude-sonnet-4-5"
    {:opencode, &__MODULE__.strip_org_prefix/1}
  ]

  # ----- public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolve the canonical id for `(provider, model_id)`. Always returns a
  non-nil binary; falls back to `"<provider>:<model_id>"` for unknowns.
  """
  @spec for_model(atom(), String.t()) :: String.t()
  def for_model(provider, model_id) when is_atom(provider) and is_binary(model_id) do
    case Map.get(@overrides, {provider, model_id}) do
      nil -> from_models_dev_or_pattern(provider, model_id)
      canonical -> canonical
    end
  end

  def for_model(_provider, _model_id), do: nil

  @doc """
  Return the rich models.dev metadata row for `(provider, model_id)` if
  one is cached. `nil` otherwise.
  """
  @spec metadata_for(atom(), String.t()) :: map() | nil
  def metadata_for(provider, model_id) when is_atom(provider) and is_binary(model_id) do
    GenServer.call(__MODULE__, {:metadata_for, provider, model_id})
  catch
    :exit, _ -> nil
  end

  @doc "Force a refresh from models.dev."
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @doc "Inspect cache state — debugging/Mix-task use."
  def info do
    GenServer.call(__MODULE__, :info)
  catch
    :exit, _ -> %{loaded: false, model_count: 0, last_fetch: nil}
  end

  # ----- internal lookups (called from for_model/2 outside the GenServer
  #       to avoid hammering the GenServer in scoring hot paths) -----

  defp from_models_dev_or_pattern(provider, model_id) do
    case lookup_models_dev(provider, model_id) do
      nil -> apply_patterns(provider, model_id)
      canonical -> canonical
    end
  end

  defp lookup_models_dev(provider, model_id) do
    case :ets.whereis(:agentic_canonical) do
      :undefined ->
        nil

      _tid ->
        case :ets.lookup(:agentic_canonical, {provider, model_id}) do
          [{_, canonical, _meta}] -> canonical
          [] -> nil
        end
    end
  end

  defp apply_patterns(provider, model_id) do
    case Enum.find(@pattern_rules, fn {p, _f} -> p == provider end) do
      {_p, fun} ->
        case fun.(model_id) do
          nil -> "#{provider}:#{model_id}"
          "" -> "#{provider}:#{model_id}"
          canonical -> canonical
        end

      nil ->
        "#{provider}:#{model_id}"
    end
  end

  @doc false
  def strip_org_prefix(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [_org, rest] -> rest
      [single] -> single
    end
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(_opts) do
    :ets.new(:agentic_canonical, [:named_table, :set, :public, read_concurrency: true])
    state = load_from_disk()

    if state.model_count > 0 do
      Logger.debug("Canonical: loaded #{state.model_count} entries from disk snapshot")
    end

    Process.send_after(self(), :refresh, @initial_refresh_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:metadata_for, provider, model_id}, _from, state) do
    meta =
      case :ets.lookup(:agentic_canonical, {provider, model_id}) do
        [{_, _canonical, meta}] -> meta
        [] -> nil
      end

    {:reply, meta, state}
  end

  def handle_call(:info, _from, state) do
    {:reply, Map.put(state, :loaded, state.model_count > 0), state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_state = do_refresh(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:refresh, state) do
    new_state = do_refresh(state)
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ----- refresh -----

  defp do_refresh(state) do
    case fetch_models_dev() do
      {:ok, payload} ->
        entries = parse_models_dev(payload)
        populate_ets(entries)
        save_to_disk(payload, entries)

        Logger.debug("Canonical: refreshed #{length(entries)} entries from models.dev")

        %{
          state
          | model_count: length(entries),
            last_fetch: DateTime.utc_now()
        }

      {:error, reason} ->
        Logger.debug("Canonical: refresh failed (#{inspect(reason)}); keeping cached snapshot")
        state
    end
  end

  defp fetch_models_dev do
    case Req.get(@models_dev_url, receive_timeout: @http_timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # The models.dev shape is:
  #   %{ "<provider>" => %{ "models" => %{ "<model_id>" => %{...metadata} } } }
  # We flatten it into [{provider_atom, model_id, canonical_id, metadata}].
  defp parse_models_dev(payload) do
    payload
    |> Enum.flat_map(fn {provider_str, provider_data} when is_map(provider_data) ->
      models = Map.get(provider_data, "models", %{})
      provider_atom = String.to_atom(provider_str)

      for {model_id, meta} when is_map(meta) <- models do
        canonical = canonical_from_models_dev(model_id, meta)
        {provider_atom, model_id, canonical, meta}
      end
    end)
  end

  # The model's `id` field on models.dev is provider-namespaced
  # (e.g. "anthropic/claude-sonnet-4"). The canonical we want is the
  # second segment if present, else the bare id.
  defp canonical_from_models_dev(model_id, meta) do
    cond do
      is_binary(meta["canonical_id"]) -> meta["canonical_id"]
      String.contains?(model_id, "/") -> strip_org_prefix(model_id)
      true -> model_id
    end
  end

  defp populate_ets(entries) do
    :ets.delete_all_objects(:agentic_canonical)

    Enum.each(entries, fn {provider, model_id, canonical, meta} ->
      :ets.insert(:agentic_canonical, {{provider, model_id}, canonical, meta})
    end)
  end

  # ----- persistence -----

  defp snapshot_path do
    System.user_home()
    |> Kernel.||(".")
    |> Path.join(".agentic/models_dev.json")
  end

  defp load_from_disk do
    path = snapshot_path()

    with {:ok, body} <- File.read(path),
         {:ok, payload} <- Jason.decode(body) do
      entries = parse_models_dev(payload)
      populate_ets(entries)
      %{model_count: length(entries), last_fetch: nil, snapshot_path: path}
    else
      _ -> %{model_count: 0, last_fetch: nil, snapshot_path: path}
    end
  end

  defp save_to_disk(payload, _entries) do
    path = snapshot_path()
    File.mkdir_p!(Path.dirname(path))

    with {:ok, json} <- Jason.encode(payload, pretty: false),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      _ -> :ok
    end
  rescue
    e -> Logger.warning("Canonical: failed to save snapshot: #{Exception.message(e)}")
  end
end
