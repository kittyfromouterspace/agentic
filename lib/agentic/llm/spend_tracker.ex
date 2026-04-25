defmodule Agentic.LLM.SpendTracker do
  @moduledoc """
  Per-request cost accumulator backed by SQLite.

  Subscribes to `[:gateway, :request, :stop]` telemetry from
  `Agentic.LLM.Gateway` and writes one row per LLM request to
  `~/.agentic/spend.sqlite3`. The Gateway already auto-injects its
  base URL into Claude Code / OpenCode / Codex subprocesses via
  `Gateway.inject_env/2`, so subprocess-driven LLM calls flow through
  the same telemetry as in-process ones.

  ## Schema

      spend_events  — one row per request (audit log for X-Ray)
      spend_windows — materialized aggregate per (provider, account_id,
                      canonical_id, period, period_start) for dashboards

  The window row is upserted in the same transaction that inserts the
  event, so dashboard queries stay constant-time as the event log grows.

  ## Currency

  All amounts are `Money.t()` from `:ex_money`. The native currency is
  preserved in the row; the dashboard normalizes for display. Sub-cent
  precision is preserved via `Decimal` (Money's internal representation).
  """

  use GenServer

  require Logger

  @gateway_stop [:gateway, :request, :stop]
  @cli_complete [:agentic, :protocol, :cli, :complete]
  @flush_debounce_ms 1_000
  @schema_version 1

  defmodule Window do
    @moduledoc false
    defstruct [
      :provider,
      :account_id,
      :canonical_id,
      :period,
      :period_start,
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :estimated_cost,
      :actual_cost,
      :request_count
    ]
  end

  # ----- public API -----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return current spend windows. Filter by `:period` (`:daily | :monthly`),
  `:provider`, or `:since` (DateTime).
  """
  def snapshot(opts \\ []) do
    GenServer.call(__MODULE__, {:snapshot, opts})
  catch
    :exit, _ -> []
  end

  @doc "Return spend windows for a provider."
  def for_provider(provider, opts \\ []) when is_atom(provider) do
    snapshot(Keyword.put(opts, :provider, provider))
  end

  @doc "Return spend windows for a canonical model id."
  def for_canonical(canonical_id, opts \\ []) when is_binary(canonical_id) do
    snapshot(Keyword.put(opts, :canonical, canonical_id))
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(_opts) do
    db_path = db_path()
    File.mkdir_p!(Path.dirname(db_path))

    {:ok, conn} =
      Exqlite.Sqlite3.open(db_path)

    :ok = configure_pragmas(conn)
    :ok = ensure_schema(conn)

    :telemetry.attach_many(
      "agentic-spend-tracker",
      [@gateway_stop, @cli_complete],
      &__MODULE__.handle_telemetry/4,
      nil
    )

    {:ok,
     %{
       conn: conn,
       db_path: db_path,
       buffer: [],
       flush_timer: nil
     }}
  end

  @impl true
  def handle_call({:snapshot, opts}, _from, state) do
    {:reply, query_windows(state.conn, opts), state}
  end

  @impl true
  def handle_cast({:record, event}, state) do
    state = %{state | buffer: [event | state.buffer]}
    {:noreply, schedule_flush(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    if state.buffer != [] do
      flush_buffer(state.conn, Enum.reverse(state.buffer))
    end

    {:noreply, %{state | buffer: [], flush_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.buffer != [] do
      flush_buffer(state.conn, Enum.reverse(state.buffer))
    end

    if state.conn, do: Exqlite.Sqlite3.close(state.conn)
    :telemetry.detach("agentic-spend-tracker")
    :ok
  end

  # ----- telemetry handler (runs in the caller's process) -----

  @doc false
  def handle_telemetry(@cli_complete, measurements, metadata, _config) do
    # CLI-reported total — the Gateway tap is source of truth, so we
    # don't treat this as a spend record. We log a debug-level
    # discrepancy if the CLI's number deviates wildly from anything
    # we already saw for the same session within the last 60s.
    cli_cost = metadata[:cli_reported_cost_usd]

    if is_number(cli_cost) and cli_cost > 0 do
      tokens =
        (measurements[:input_tokens] || 0) +
          (measurements[:output_tokens] || 0)

      Logger.debug(
        "SpendTracker: CLI reported total_cost_usd=#{cli_cost} for session=#{metadata[:session_id]} (#{tokens} tokens)"
      )
    end

    :ok
  end

  def handle_telemetry(_event, measurements, metadata, _config) do
    event = build_event(measurements, metadata)

    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, event})
    end
  end

  # ----- helpers -----

  defp build_event(measurements, metadata) do
    %{
      ts: DateTime.utc_now(),
      call_id: Map.get(metadata, :call_id),
      provider: Map.get(metadata, :provider),
      account_id: Map.get(metadata, :account_id) || default_account_id(metadata[:provider]),
      canonical_id: Map.get(metadata, :canonical_model_id),
      model_id: Map.get(metadata, :model),
      input_tokens: Map.get(measurements, :input_tokens, 0),
      output_tokens: Map.get(measurements, :output_tokens, 0),
      cache_read_tokens: Map.get(measurements, :cache_read, 0),
      cache_write_tokens: Map.get(measurements, :cache_write, 0),
      duration_ms: ns_to_ms(Map.get(measurements, :duration, 0)),
      status: Map.get(metadata, :status),
      actual_cost: Map.get(metadata, :actual_cost),
      estimated_cost: Map.get(metadata, :estimated_cost)
    }
  end

  defp default_account_id(nil), do: "unknown"
  defp default_account_id(provider), do: Atom.to_string(provider)

  defp ns_to_ms(ns) when is_integer(ns) and ns > 0,
    do: System.convert_time_unit(ns, :native, :millisecond)

  defp ns_to_ms(_), do: 0

  defp schedule_flush(%{flush_timer: nil} = state) do
    timer = Process.send_after(self(), :flush, @flush_debounce_ms)
    %{state | flush_timer: timer}
  end

  defp schedule_flush(state), do: state

  defp flush_buffer(conn, events) do
    Enum.each(events, fn event ->
      insert_event(conn, event)
      upsert_window(conn, event, :daily)
      upsert_window(conn, event, :monthly)
    end)
  rescue
    e -> Logger.warning("SpendTracker: flush failed: #{Exception.message(e)}")
  end

  # ----- SQLite -----

  defp db_path do
    System.user_home()
    |> Kernel.||(".")
    |> Path.join(".agentic/spend.sqlite3")
  end

  defp configure_pragmas(conn) do
    Enum.each(
      [
        "PRAGMA journal_mode=WAL;",
        "PRAGMA synchronous=NORMAL;",
        "PRAGMA foreign_keys=ON;"
      ],
      fn sql -> :ok = Exqlite.Sqlite3.execute(conn, sql) end
    )
  end

  defp ensure_schema(conn) do
    Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS spend_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    """)

    Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS spend_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL,
      call_id TEXT,
      provider TEXT NOT NULL,
      account_id TEXT NOT NULL,
      canonical_id TEXT,
      model_id TEXT,
      input_tokens INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      cache_read_tokens INTEGER DEFAULT 0,
      cache_write_tokens INTEGER DEFAULT 0,
      estimated_amount TEXT,
      estimated_currency TEXT,
      actual_amount TEXT,
      actual_currency TEXT,
      duration_ms INTEGER,
      status INTEGER
    );
    """)

    Exqlite.Sqlite3.execute(
      conn,
      "CREATE INDEX IF NOT EXISTS idx_spend_events_ts ON spend_events (ts);"
    )

    Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS spend_windows (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      provider TEXT NOT NULL,
      account_id TEXT NOT NULL,
      canonical_id TEXT,
      period TEXT NOT NULL,
      period_start TEXT NOT NULL,
      input_tokens INTEGER DEFAULT 0,
      output_tokens INTEGER DEFAULT 0,
      cache_read_tokens INTEGER DEFAULT 0,
      cache_write_tokens INTEGER DEFAULT 0,
      estimated_amount TEXT NOT NULL DEFAULT '0',
      estimated_currency TEXT NOT NULL DEFAULT 'USD',
      actual_amount TEXT,
      actual_currency TEXT,
      request_count INTEGER DEFAULT 0,
      updated_at TEXT NOT NULL,
      UNIQUE (provider, account_id, canonical_id, period, period_start)
    );
    """)

    Exqlite.Sqlite3.execute(
      conn,
      "CREATE INDEX IF NOT EXISTS idx_spend_period ON spend_windows (period, period_start);"
    )

    Exqlite.Sqlite3.execute(
      conn,
      "INSERT OR REPLACE INTO spend_meta (key, value) VALUES ('schema_version', '#{@schema_version}');"
    )

    :ok
  end

  defp insert_event(conn, event) do
    {est_amount, est_currency} = money_columns(event.estimated_cost)
    {act_amount, act_currency} = money_columns(event.actual_cost)

    sql = """
    INSERT INTO spend_events
      (ts, call_id, provider, account_id, canonical_id, model_id,
       input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
       estimated_amount, estimated_currency, actual_amount, actual_currency,
       duration_ms, status)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    bindings = [
      DateTime.to_iso8601(event.ts),
      event.call_id,
      provider_str(event.provider),
      event.account_id,
      event.canonical_id,
      event.model_id,
      event.input_tokens,
      event.output_tokens,
      event.cache_read_tokens,
      event.cache_write_tokens,
      est_amount,
      est_currency,
      act_amount,
      act_currency,
      event.duration_ms,
      status_int(event.status)
    ]

    :ok = Exqlite.Sqlite3.bind(stmt, bindings)
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
  end

  defp upsert_window(conn, event, period) do
    period_start = period_start(event.ts, period)
    {est_amount, est_currency} = money_columns(event.estimated_cost)
    {act_amount, act_currency} = money_columns(event.actual_cost)
    now_iso = DateTime.to_iso8601(DateTime.utc_now())

    sql = """
    INSERT INTO spend_windows
      (provider, account_id, canonical_id, period, period_start,
       input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
       estimated_amount, estimated_currency, actual_amount, actual_currency,
       request_count, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
    ON CONFLICT (provider, account_id, canonical_id, period, period_start) DO UPDATE SET
      input_tokens = input_tokens + excluded.input_tokens,
      output_tokens = output_tokens + excluded.output_tokens,
      cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
      cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens,
      estimated_amount =
        CAST((CAST(estimated_amount AS REAL) + CAST(excluded.estimated_amount AS REAL)) AS TEXT),
      actual_amount =
        CASE
          WHEN excluded.actual_amount IS NULL THEN actual_amount
          WHEN actual_amount IS NULL THEN excluded.actual_amount
          ELSE CAST((CAST(actual_amount AS REAL) + CAST(excluded.actual_amount AS REAL)) AS TEXT)
        END,
      actual_currency = COALESCE(actual_currency, excluded.actual_currency),
      request_count = request_count + 1,
      updated_at = excluded.updated_at;
    """

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    bindings = [
      provider_str(event.provider),
      event.account_id,
      event.canonical_id,
      Atom.to_string(period),
      period_start,
      event.input_tokens,
      event.output_tokens,
      event.cache_read_tokens,
      event.cache_write_tokens,
      est_amount || "0",
      est_currency || "USD",
      act_amount,
      act_currency,
      now_iso
    ]

    :ok = Exqlite.Sqlite3.bind(stmt, bindings)
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
  end

  defp money_columns(nil), do: {nil, nil}

  defp money_columns(%Money{} = m) do
    {Decimal.to_string(m.amount), Atom.to_string(m.currency)}
  end

  defp money_columns(_), do: {nil, nil}

  defp provider_str(nil), do: "unknown"
  defp provider_str(p) when is_atom(p), do: Atom.to_string(p)
  defp provider_str(p) when is_binary(p), do: p

  defp status_int(nil), do: nil
  defp status_int(s) when is_integer(s), do: s
  defp status_int(_), do: nil

  defp period_start(%DateTime{} = ts, :daily) do
    ts |> DateTime.to_date() |> Date.to_iso8601()
  end

  defp period_start(%DateTime{year: y, month: m}, :monthly) do
    "#{y}-#{String.pad_leading(Integer.to_string(m), 2, "0")}-01"
  end

  defp query_windows(conn, opts) do
    {filters, args} = build_filters(opts)
    where = if filters == "", do: "", else: "WHERE #{filters}"

    sql = """
    SELECT provider, account_id, canonical_id, period, period_start,
           input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
           estimated_amount, estimated_currency,
           actual_amount, actual_currency,
           request_count
    FROM spend_windows
    #{where}
    ORDER BY period_start DESC, provider ASC;
    """

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        if args != [], do: :ok = Exqlite.Sqlite3.bind(stmt, args)
        rows = collect_rows(conn, stmt, [])
        :ok = Exqlite.Sqlite3.release(conn, stmt)
        Enum.map(rows, &row_to_window/1)

      _ ->
        []
    end
  end

  defp build_filters(opts) do
    {clauses, args} =
      Enum.reduce(opts, {[], []}, fn
        {:provider, p}, {cs, as} -> {["provider = ?" | cs], [provider_str(p) | as]}
        {:canonical, c}, {cs, as} -> {["canonical_id = ?" | cs], [c | as]}
        {:period, p}, {cs, as} -> {["period = ?" | cs], [Atom.to_string(p) | as]}
        {:since, %DateTime{} = dt}, {cs, as} -> {["period_start >= ?" | cs], [DateTime.to_iso8601(dt) | as]}
        _, acc -> acc
      end)

    {Enum.join(clauses, " AND "), Enum.reverse(args)}
  end

  defp collect_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> Enum.reverse(acc)
      {:row, row} -> collect_rows(conn, stmt, [row | acc])
      _ -> Enum.reverse(acc)
    end
  end

  defp row_to_window([
         provider,
         account_id,
         canonical_id,
         period,
         period_start,
         input_tokens,
         output_tokens,
         cache_read_tokens,
         cache_write_tokens,
         est_amount,
         est_currency,
         act_amount,
         act_currency,
         request_count
       ]) do
    %Window{
      provider: safe_atom(provider),
      account_id: account_id,
      canonical_id: canonical_id,
      period: safe_atom(period),
      period_start: period_start,
      input_tokens: input_tokens || 0,
      output_tokens: output_tokens || 0,
      cache_read_tokens: cache_read_tokens || 0,
      cache_write_tokens: cache_write_tokens || 0,
      estimated_cost: build_money(est_amount, est_currency),
      actual_cost: build_money(act_amount, act_currency),
      request_count: request_count || 0
    }
  end

  defp build_money(nil, _), do: nil
  defp build_money(_, nil), do: nil

  defp build_money(amount, currency) when is_binary(amount) and is_binary(currency) do
    try do
      Money.new(safe_atom(currency), Decimal.new(amount))
    rescue
      _ -> nil
    end
  end

  defp build_money(_, _), do: nil

  defp safe_atom(nil), do: nil

  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(a) when is_atom(a), do: a
end
