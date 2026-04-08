defmodule AgentEx.LLM.UsageManager do
  @moduledoc """
  Periodically polls every enabled provider that implements
  `fetch_usage/1` and caches the latest snapshot. Worth's status
  sidebar reads from this cache.

  ## Public API

      AgentEx.LLM.UsageManager.snapshot()                    # all known usages
      AgentEx.LLM.UsageManager.for_provider(:openrouter)     # one provider
      AgentEx.LLM.UsageManager.refresh()                     # async
      AgentEx.LLM.UsageManager.refresh_provider(:openrouter) # async
  """

  use GenServer

  alias AgentEx.LLM.{Credentials, ProviderRegistry, Usage}

  require Logger

  @default_interval_ms 5 * 60 * 1000
  @first_refresh_delay_ms 500

  # ----- public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all cached usage snapshots."
  @spec snapshot() :: [Usage.t()]
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  catch
    :exit, _ -> []
  end

  @doc "Return the cached snapshot for one provider, or nil."
  @spec for_provider(atom()) :: Usage.t() | nil
  def for_provider(provider_id) when is_atom(provider_id) do
    GenServer.call(__MODULE__, {:for_provider, provider_id})
  catch
    :exit, _ -> nil
  end

  @doc "Trigger an async refresh of every enabled provider."
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Trigger an async refresh of one provider."
  def refresh_provider(provider_id) when is_atom(provider_id) do
    GenServer.cast(__MODULE__, {:refresh_provider, provider_id})
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(_opts) do
    interval =
      :agent_ex
      |> Application.get_env(:usage, [])
      |> Keyword.get(:refresh_interval_ms, @default_interval_ms)

    state = %{usages: %{}, interval_ms: interval}

    Process.send_after(self(), :first_refresh, @first_refresh_delay_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.values(state.usages), state}
  end

  def handle_call({:for_provider, provider_id}, _from, state) do
    {:reply, Map.get(state.usages, provider_id), state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_usages = refresh_all()
    {:noreply, %{state | usages: new_usages}}
  end

  def handle_cast({:refresh_provider, provider_id}, state) do
    new_usages =
      case refresh_one(provider_id) do
        {:ok, usage} -> Map.put(state.usages, provider_id, usage)
        :skip -> state.usages
      end

    {:noreply, %{state | usages: new_usages}}
  end

  @impl true
  def handle_info(:first_refresh, state) do
    new_usages = refresh_all()
    schedule_next(state.interval_ms)
    {:noreply, %{state | usages: new_usages}}
  end

  def handle_info(:scheduled_refresh, state) do
    new_usages = refresh_all()
    schedule_next(state.interval_ms)
    {:noreply, %{state | usages: new_usages}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ----- internals -----

  defp schedule_next(interval_ms) do
    Process.send_after(self(), :scheduled_refresh, interval_ms)
  end

  defp refresh_all do
    ProviderRegistry.enabled()
    |> Enum.reduce(%{}, fn %{id: id}, acc ->
      case refresh_one(id) do
        {:ok, usage} -> Map.put(acc, id, usage)
        :skip -> acc
      end
    end)
  end

  defp refresh_one(provider_id) do
    case ProviderRegistry.get(provider_id) do
      nil ->
        :skip

      module ->
        if function_exported?(module, :fetch_usage, 1) do
          case Credentials.resolve(module) do
            {:ok, creds} ->
              call_fetch_usage(module, creds)

            :not_configured ->
              :skip
          end
        else
          :skip
        end
    end
  end

  defp call_fetch_usage(module, creds) do
    case module.fetch_usage(creds) do
      {:ok, %Usage{} = usage} ->
        {:ok, usage}

      {:ok, body} when is_map(body) ->
        {:ok,
         %Usage{
           provider: module.id(),
           label: module.label(),
           windows: [],
           credits: nil,
           error: nil,
           fetched_at: System.system_time(:millisecond)
         }}

      :not_supported ->
        :skip

      other ->
        Logger.debug("UsageManager: #{module.id()} fetch_usage returned #{inspect(other)}")
        :skip
    end
  rescue
    e ->
      Logger.debug("UsageManager: #{module.id()} fetch_usage raised #{Exception.message(e)}")
      :skip
  end
end
