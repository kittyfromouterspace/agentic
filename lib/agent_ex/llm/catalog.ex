defmodule AgentEx.LLM.Catalog do
  @moduledoc """
  Unified model catalog backed by a GenServer.

  Holds all known models from three sources (priority order):
    1. User overrides from `~/.worth/config.exs`
    2. Dynamic discovery from `provider.fetch_catalog/1`
    3. Provider's static `default_models/0`

  Persisted to `~/.worth/catalog.json` (schema-versioned).
  Loaded at boot for warm-path latency, refreshed async in background.
  """

  use GenServer

  alias AgentEx.LLM.{Credentials, Model}

  require Logger

  @schema_version 1
  @refresh_interval_ms 10 * 60 * 1000
  @first_refresh_delay_ms 100

  # ----- public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all models in the catalog."
  def all do
    GenServer.call(__MODULE__, :all)
  catch
    :exit, _ -> []
  end

  @doc "Return models for a specific provider."
  def for_provider(provider_id) when is_atom(provider_id) do
    GenServer.call(__MODULE__, {:for_provider, provider_id})
  catch
    :exit, _ -> []
  end

  @doc """
  Find models matching filters.

  Options:
    * `:provider` — filter by provider atom
    * `:tier` — filter by tier_hint (`:primary`, `:lightweight`)
    * `:has` — capability tag or list of tags (all must be present)
    * `:source` — filter by source (`:static`, `:discovered`, `:user_config`)
  """
  def find(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:find, opts})
  catch
    :exit, _ -> []
  end

  @doc "Look up a single model by provider and model id."
  def lookup(provider_id, model_id) do
    GenServer.call(__MODULE__, {:lookup, provider_id, model_id})
  catch
    :exit, _ -> nil
  end

  @doc "Trigger an async refresh of all enabled providers."
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Trigger an async refresh of a single provider."
  def refresh_provider(provider_id) do
    GenServer.cast(__MODULE__, {:refresh_provider, provider_id})
  end

  @doc "Return catalog metadata (counts, last refresh, etc)."
  def info do
    GenServer.call(__MODULE__, :info)
  catch
    :exit, _ -> %{model_count: 0, last_refresh: nil}
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(_opts) do
    state = load_from_disk()

    send(self(), :initial_refresh)

    {:ok, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, Map.values(state.models), state}
  end

  def handle_call({:for_provider, provider_id}, _from, state) do
    models =
      state.models
      |> Map.values()
      |> Enum.filter(&(&1.provider == provider_id))

    {:reply, models, state}
  end

  def handle_call({:find, opts}, _from, state) do
    models = Map.values(state.models)

    filtered =
      models
      |> maybe_filter_provider(opts)
      |> maybe_filter_tier(opts)
      |> maybe_filter_has(opts)
      |> maybe_filter_source(opts)

    {:reply, filtered, state}
  end

  def handle_call({:lookup, provider_id, model_id}, _from, state) do
    key = {provider_id, model_id}
    {:reply, Map.get(state.models, key), state}
  end

  def handle_call(:info, _from, state) do
    info = %{
      model_count: map_size(state.models),
      last_refresh: state.last_refresh,
      providers: state.provider_stats
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_state = do_refresh(state)
    {:noreply, new_state}
  end

  def handle_cast({:refresh_provider, provider_id}, state) do
    new_state = do_refresh_provider(state, provider_id)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:initial_refresh, state) do
    Process.send_after(self(), :scheduled_refresh, @first_refresh_delay_ms)
    {:noreply, state}
  end

  def handle_info(:scheduled_refresh, state) do
    new_state = do_refresh(state)
    Process.send_after(self(), :scheduled_refresh, @refresh_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ----- refresh logic -----

  defp do_refresh(state) do
    providers = enabled_providers()
    provider_stats = %{}

    {models, provider_stats} =
      Enum.reduce(providers, {state.models, provider_stats}, fn module, {acc, stats} ->
        {new_models, stat} = fetch_provider_models(module)
        merged = merge_models(acc, new_models, module.id())
        {merged, Map.put(stats, module.id(), stat)}
      end)

    new_state = %{state | models: models, last_refresh: DateTime.utc_now(), provider_stats: provider_stats}
    save_to_disk(new_state)
    new_state
  end

  defp do_refresh_provider(state, provider_id) do
    case find_provider_module(provider_id) do
      nil ->
        state

      module ->
        {new_models, stat} = fetch_provider_models(module)
        merged = merge_models(state.models, new_models, provider_id)
        stats = Map.put(state.provider_stats, provider_id, stat)
        new_state = %{state | models: merged, provider_stats: stats}
        save_to_disk(new_state)
        new_state
    end
  end

  defp fetch_provider_models(module) do
    case Credentials.resolve(module) do
      {:ok, creds} ->
        case module.fetch_catalog(creds) do
          {:ok, models} when is_list(models) ->
            Logger.debug("Catalog: fetched #{length(models)} models from #{module.id()}")
            {models, %{status: :ok, count: length(models), source: :discovered}}

          {:error, reason} ->
            Logger.debug("Catalog: fetch failed for #{module.id()}: #{inspect(reason)}")
            {module.default_models(), %{status: :fallback, count: length(module.default_models()), source: :static}}

          :not_supported ->
            {module.default_models(), %{status: :static, count: length(module.default_models()), source: :static}}
        end

      :not_configured ->
        {module.default_models(), %{status: :no_creds, count: length(module.default_models()), source: :static}}
    end
  end

  defp merge_models(existing, new_models, provider_id) do
    existing
    |> Map.filter(fn {{pid, _}, _} -> pid != provider_id end)
    |> then(fn base ->
      Enum.reduce(new_models, base, fn model, acc ->
        Map.put(acc, {model.provider || provider_id, model.id}, model)
      end)
    end)
  end

  defp enabled_providers do
    try do
      AgentEx.LLM.ProviderRegistry.enabled()
      |> Enum.map(& &1.module)
    catch
      :exit, _ -> AgentEx.Config.providers()
    end
  end

  defp find_provider_module(provider_id) do
    Enum.find(enabled_providers(), &(&1.id() == provider_id))
  end

  # ----- persistence -----

  defp load_from_disk do
    path = catalog_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"schema_version" => @schema_version, "models" => models_data}} ->
            models = decode_models(models_data)
            Logger.debug("Catalog: loaded #{map_size(models)} models from #{path}")
            %{models: models, last_refresh: nil, provider_stats: %{}}

          {:ok, %{"schema_version" => v}} ->
            Logger.warning("Catalog: schema version mismatch (#{v} vs #{@schema_version}), forcing refresh")
            %{models: seed_static_models(), last_refresh: nil, provider_stats: %{}}

          _ ->
            %{models: seed_static_models(), last_refresh: nil, provider_stats: %{}}
        end

      {:error, _} ->
        %{models: seed_static_models(), last_refresh: nil, provider_stats: %{}}
    end
  end

  defp save_to_disk(state) do
    path = catalog_path()

    data = %{
      schema_version: @schema_version,
      saved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      models: encode_models(state.models)
    }

    dir = Path.dirname(path)
    unless File.dir?(dir), do: File.mkdir_p!(dir)

    # Atomic write: stage to a tempfile in the same directory, then
    # rename. Crash mid-write leaves the previous catalog intact rather
    # than truncating to garbage.
    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        tmp = path <> ".tmp"

        with :ok <- File.write(tmp, json),
             :ok <- File.rename(tmp, path) do
          :ok
        else
          _ ->
            File.rm(tmp)
            :ok
        end

      _ ->
        :ok
    end
  rescue
    e -> Logger.warning("Catalog: failed to save: #{Exception.message(e)}")
  end

  defp catalog_path do
    AgentEx.Config.catalog(:persist_path, "~/.worth/catalog.json")
    |> Path.expand()
  end

  defp seed_static_models do
    AgentEx.Config.providers()
    |> Enum.flat_map(fn module ->
      module.default_models()
      |> Enum.map(fn model -> {{model.provider || module.id(), model.id}, model} end)
    end)
    |> Map.new()
  end

  defp encode_models(models) do
    models
    |> Map.values()
    |> Enum.map(fn m ->
      %{
        "id" => m.id,
        "provider" => m.provider,
        "label" => m.label,
        "context_window" => m.context_window,
        "max_output_tokens" => m.max_output_tokens,
        "cost" => m.cost,
        "capabilities" => MapSet.to_list(m.capabilities),
        "tier_hint" => m.tier_hint,
        "source" => m.source
      }
    end)
  end

  defp decode_models(models_data) when is_list(models_data) do
    models_data
    |> Enum.map(fn data ->
      model = %Model{
        id: data["id"],
        provider: data["provider"],
        label: data["label"],
        context_window: data["context_window"],
        max_output_tokens: data["max_output_tokens"],
        cost: data["cost"],
        capabilities: MapSet.new(data["capabilities"] || []),
        tier_hint: data["tier_hint"],
        source: (data["source"] || "static") |> to_atom_if_possible()
      }

      {{model.provider, model.id}, model}
    end)
    |> Map.new()
  end

  defp decode_models(_), do: %{}

  defp to_atom_if_possible(s) when is_binary(s), do: String.to_existing_atom(s)
  defp to_atom_if_possible(a) when is_atom(a), do: a

  # ----- filter helpers -----

  defp maybe_filter_provider(models, opts) do
    case Keyword.get(opts, :provider) do
      nil -> models
      pid -> Enum.filter(models, &(&1.provider == pid))
    end
  end

  defp maybe_filter_tier(models, opts) do
    case Keyword.get(opts, :tier) do
      nil -> models
      tier -> Enum.filter(models, &(&1.tier_hint == tier))
    end
  end

  defp maybe_filter_has(models, opts) do
    case Keyword.get(opts, :has) do
      nil ->
        models

      tags when is_list(tags) ->
        Enum.filter(models, fn m ->
          Enum.all?(tags, &MapSet.member?(m.capabilities, &1))
        end)

      tag when is_atom(tag) ->
        Enum.filter(models, &MapSet.member?(&1.capabilities, tag))
    end
  end

  defp maybe_filter_source(models, opts) do
    case Keyword.get(opts, :source) do
      nil -> models
      source -> Enum.filter(models, &(&1.source == source))
    end
  end
end
