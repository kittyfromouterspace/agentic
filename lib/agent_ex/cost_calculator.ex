defmodule AgentEx.CostCalculator do
  @moduledoc """
  Calculates LLM costs from token counts and model pricing data.

  Uses a hardcoded fallback pricing table. All rates are per million tokens (mtok).
  """

  # {input_rate_per_mtok, output_rate_per_mtok}
  @fallback_pricing %{
    # Anthropic
    "claude-opus-4-6" => {15.0, 75.0},
    "claude-sonnet-4-5-20250929" => {3.0, 15.0},
    "claude-sonnet-4-6" => {3.0, 15.0},
    "claude-haiku-4-5-20251001" => {1.0, 5.0},
    # OpenAI
    "gpt-4o" => {2.5, 10.0},
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4-turbo" => {10.0, 30.0},
    "o1" => {15.0, 60.0},
    "o1-mini" => {1.10, 4.40},
    "o3-mini" => {1.10, 4.40}
  }

  @doc """
  Calculate cost in USD from token counts and model pricing.

  Returns 0.0 if pricing cannot be determined.
  """
  @spec calculate(String.t() | nil, String.t() | nil, non_neg_integer(), non_neg_integer()) ::
          float()
  def calculate(_provider_name, _model_id, 0, 0), do: 0.0
  def calculate(nil, nil, _input, _output), do: 0.0

  def calculate(_provider_name, model_id, input_tokens, output_tokens) do
    case lookup_pricing(model_id) do
      {input_rate, output_rate} ->
        input_tokens / 1_000_000.0 * input_rate + output_tokens / 1_000_000.0 * output_rate

      nil ->
        0.0
    end
  end

  @doc """
  Returns the hardcoded fallback pricing table as a map of
  `%{model_id => {input_rate, output_rate}}`.
  """
  @spec lookup_pricing_table() :: %{String.t() => {float(), float()}}
  def lookup_pricing_table, do: @fallback_pricing

  @doc """
  Look up pricing for a model. Returns `{input_rate, output_rate}` or `nil`.
  """
  @spec lookup_pricing(String.t() | nil) :: {float(), float()} | nil
  def lookup_pricing(nil), do: nil
  def lookup_pricing(model_id), do: Map.get(@fallback_pricing, model_id)
end
