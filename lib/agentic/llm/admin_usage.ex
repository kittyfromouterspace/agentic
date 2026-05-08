defmodule Agentic.LLM.AdminUsage do
  @moduledoc """
  Pollers for provider organization-level usage / cost APIs.

  These endpoints require **separate** admin-tier keys distinct from
  the regular API keys the agent uses for inference:

    * Anthropic — `sk-ant-admin-...`, organization-tier accounts only.
    * OpenAI — `sk-admin-...`, minted by an org Owner; available on
      all paid tiers.

  Worth surfaces these as a separate "Connect organization for usage
  reporting" flow in settings — they're strictly read-only billing
  endpoints, but they are more sensitive than regular keys (read all
  org usage, list members, manage keys).

  Both providers split usage and cost across two endpoints. We return
  a normalized shape here; SpendTracker reconciles against
  gateway-derived rows for the same period.
  """

  require Logger

  @anthropic_usage_url "https://api.anthropic.com/v1/organizations/usage_report/messages"
  @anthropic_cost_url "https://api.anthropic.com/v1/organizations/cost_report"
  @anthropic_version "2023-06-01"
  @openai_base "https://api.openai.com/v1/organization"
  @http_timeout_ms 30_000

  @type bucket :: %{
          period_start: DateTime.t(),
          period_end: DateTime.t(),
          model: String.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer(),
          request_count: non_neg_integer(),
          actual_cost: Money.t() | nil
        }

  @type opts :: [
          since: DateTime.t(),
          until: DateTime.t(),
          bucket_width: :daily | :hourly,
          group_by: [String.t()]
        ]

  # ----- Anthropic -----

  @doc """
  Poll Anthropic Admin API for usage and cost over `opts[:since]..opts[:until]`.

  Returns `{:ok, [bucket]}` or `{:error, reason}`. The two endpoints
  (usage_report/messages and cost_report) are merged on
  `(period_start, model, service_tier)`.
  """
  @spec poll_anthropic(String.t(), opts()) :: {:ok, [bucket]} | {:error, term()}
  def poll_anthropic(admin_key, opts \\ []) when is_binary(admin_key) do
    with {:ok, usage_buckets} <- anthropic_usage(admin_key, opts),
         {:ok, cost_buckets} <- anthropic_cost(admin_key, opts) do
      {:ok, merge_anthropic(usage_buckets, cost_buckets)}
    end
  end

  defp anthropic_usage(admin_key, opts) do
    params = anthropic_params(opts) ++ [group_by: ~w(model service_tier context_window)]

    case Req.get(@anthropic_usage_url,
           headers: anthropic_headers(admin_key),
           params: params,
           receive_timeout: @http_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"data" => buckets}}} -> {:ok, buckets}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp anthropic_cost(admin_key, opts) do
    params = anthropic_params(opts)

    case Req.get(@anthropic_cost_url,
           headers: anthropic_headers(admin_key),
           params: params,
           receive_timeout: @http_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"data" => buckets}}} -> {:ok, buckets}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp anthropic_headers(admin_key) do
    [
      {"x-api-key", admin_key},
      {"anthropic-version", @anthropic_version}
    ]
  end

  defp anthropic_params(opts) do
    starting = opts[:since] |> default_since() |> DateTime.to_iso8601()
    ending = opts[:until] |> default_until() |> DateTime.to_iso8601()
    bucket = bucket_width(opts[:bucket_width])

    [
      starting_at: starting,
      ending_at: ending,
      bucket_width: bucket
    ]
  end

  defp merge_anthropic(usage_buckets, cost_buckets) do
    cost_index =
      Enum.reduce(cost_buckets, %{}, fn b, acc ->
        key = bucket_key(b)
        Map.put(acc, key, b)
      end)

    Enum.map(usage_buckets, fn ub ->
      cb = Map.get(cost_index, bucket_key(ub))
      build_anthropic_bucket(ub, cb)
    end)
  end

  defp build_anthropic_bucket(ub, cb) do
    results = ub["results"] || [%{}]
    cost_results = (cb && cb["results"]) || []
    primary = List.first(results) || %{}
    primary_cost = List.first(cost_results)

    %{
      period_start: parse_iso(ub["starting_at"]),
      period_end: parse_iso(ub["ending_at"]),
      model: primary["model"],
      input_tokens: primary["uncached_input_tokens"] || 0,
      output_tokens: primary["output_tokens"] || 0,
      cache_read_tokens: primary["cache_read_input_tokens"] || 0,
      cache_write_tokens: cache_write_total(primary["cache_creation"]),
      request_count: 0,
      actual_cost: build_money_from_cost(primary_cost && primary_cost["amount"])
    }
  end

  defp cache_write_total(nil), do: 0

  defp cache_write_total(%{} = m) do
    (m["ephemeral_5m_input_tokens"] || 0) + (m["ephemeral_1h_input_tokens"] || 0)
  end

  defp bucket_key(%{"starting_at" => s, "results" => [%{"model" => m} | _]}), do: {s, m}
  defp bucket_key(%{"starting_at" => s}), do: {s, nil}

  # ----- OpenAI -----

  @doc """
  Poll OpenAI Admin API for completion usage and total costs.

  Returns `{:ok, [bucket]}`. The two endpoints
  (`/usage/completions` and `/costs`) are merged on `period_start`.
  Other modality endpoints (embeddings, images, audio) are ignored —
  add them when there's a use case.
  """
  @spec poll_openai(String.t(), opts()) :: {:ok, [bucket]} | {:error, term()}
  def poll_openai(admin_key, opts \\ []) when is_binary(admin_key) do
    with {:ok, usage_buckets} <- openai_completions_usage(admin_key, opts),
         {:ok, cost_buckets} <- openai_costs(admin_key, opts) do
      {:ok, merge_openai(usage_buckets, cost_buckets)}
    end
  end

  defp openai_completions_usage(admin_key, opts) do
    params = openai_params(opts) ++ [group_by: "model"]

    case Req.get("#{@openai_base}/usage/completions",
           headers: openai_headers(admin_key),
           params: params,
           receive_timeout: @http_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"data" => buckets}}} -> {:ok, buckets}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp openai_costs(admin_key, opts) do
    # OpenAI /costs only supports bucket_width=1d.
    params = openai_params(opts) |> Keyword.put(:bucket_width, "1d")

    case Req.get("#{@openai_base}/costs",
           headers: openai_headers(admin_key),
           params: params,
           receive_timeout: @http_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"data" => buckets}}} -> {:ok, buckets}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp openai_headers(admin_key) do
    [{"authorization", "Bearer #{admin_key}"}]
  end

  defp openai_params(opts) do
    starting_unix =
      opts[:since] |> default_since() |> DateTime.to_unix()

    ending_unix =
      opts[:until] |> default_until() |> DateTime.to_unix()

    [
      start_time: starting_unix,
      end_time: ending_unix,
      bucket_width: bucket_width(opts[:bucket_width])
    ]
  end

  defp merge_openai(usage_buckets, cost_buckets) do
    cost_index =
      Enum.reduce(cost_buckets, %{}, fn b, acc ->
        Map.put(acc, b["start_time"], b)
      end)

    Enum.map(usage_buckets, fn ub ->
      cb = Map.get(cost_index, ub["start_time"])
      build_openai_bucket(ub, cb)
    end)
  end

  defp build_openai_bucket(ub, cb) do
    results = ub["results"] || [%{}]
    primary = List.first(results) || %{}

    cost_total =
      case cb && cb["results"] do
        nil ->
          nil

        list when is_list(list) ->
          list
          |> Enum.map(& &1["amount"])
          |> Enum.reject(&is_nil/1)
          |> sum_amounts()
      end

    %{
      period_start: unix_to_dt(ub["start_time"]),
      period_end: unix_to_dt(ub["end_time"]),
      model: primary["model"],
      input_tokens: primary["input_tokens"] || 0,
      output_tokens: primary["output_tokens"] || 0,
      cache_read_tokens: primary["input_cached_tokens"] || 0,
      cache_write_tokens: 0,
      request_count: primary["num_model_requests"] || 0,
      actual_cost: build_money_from_amount(cost_total)
    }
  end

  defp sum_amounts([]), do: nil

  defp sum_amounts(amounts) do
    Enum.reduce(amounts, %{"value" => 0.0, "currency" => "usd"}, fn a, acc ->
      %{
        "value" => (acc["value"] || 0.0) + (a["value"] || 0.0),
        "currency" => acc["currency"] || a["currency"] || "usd"
      }
    end)
  end

  # ----- shared helpers -----

  defp default_since(nil), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp default_since(%DateTime{} = dt), do: dt

  defp default_until(nil), do: DateTime.utc_now()
  defp default_until(%DateTime{} = dt), do: dt

  defp bucket_width(nil), do: "1d"
  defp bucket_width(:daily), do: "1d"
  defp bucket_width(:hourly), do: "1h"
  defp bucket_width(s) when is_binary(s), do: s

  defp parse_iso(nil), do: nil

  defp parse_iso(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp unix_to_dt(nil), do: nil
  defp unix_to_dt(n) when is_integer(n), do: DateTime.from_unix!(n)

  defp build_money_from_cost(nil), do: nil

  defp build_money_from_cost(%{"value" => v, "currency" => c})
       when is_number(v) and is_binary(c) do
    Money.from_float(currency_atom(c), v)
  rescue
    _ -> nil
  end

  defp build_money_from_cost(_), do: nil

  defp build_money_from_amount(nil), do: nil

  defp build_money_from_amount(%{"value" => v, "currency" => c}),
    do: build_money_from_cost(%{"value" => v, "currency" => c})

  defp currency_atom(s) when is_binary(s) do
    s |> String.upcase() |> String.to_atom()
  end
end
