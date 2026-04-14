defmodule AgentEx.ModelRouter.Preference do
  @moduledoc """
  Defines model selection preferences and the scoring logic for each.

  User preferences control how the Selector ranks candidate models:

    * `:optimize_price` — prefer cheaper models; only upgrade when
      the analysis demands it (complex tasks, vision, etc.)
    * `:optimize_speed` — prefer faster models; prioritize throughput
      and low latency, willing to spend more

  The preference is combined with an `Analyzer.analysis()` result to
  produce a scoring function used by `Selector.rank/3`.
  """

  @type preference :: :optimize_price | :optimize_speed

  @doc "Parse a preference from user input."
  @spec parse(term()) :: {:ok, preference()} | {:error, term()}
  def parse(:optimize_price), do: {:ok, :optimize_price}
  def parse(:optimize_speed), do: {:ok, :optimize_speed}
  def parse("price"), do: {:ok, :optimize_price}
  def parse("speed"), do: {:ok, :optimize_speed}
  def parse("optimize_price"), do: {:ok, :optimize_price}
  def parse("optimize_speed"), do: {:ok, :optimize_speed}
  def parse(other), do: {:error, {:invalid_preference, other}}

  @doc "Return the default preference."
  @spec default() :: preference()
  def default, do: :optimize_price

  alias AgentEx.LLM.Model
  alias AgentEx.ModelRouter.Analyzer

  @doc """
  Compute a score for a model given a preference and analysis.

  Lower scores are better. The scoring considers:
  - Base cost or speed rating
  - Complexity-appropriate tier matching
  - Capability matching (vision, reasoning, etc.)
  - Penalty for missing required capabilities
  """
  @spec score(Model.t(), preference(), Analyzer.analysis()) :: float()
  def score(model, preference, analysis) do
    base_score = base_score(model, preference)
    complexity_adjustment = complexity_adjustment(model, analysis.complexity, preference)
    capability_penalty = capability_penalty(model, analysis)
    context_adjustment = context_adjustment(model, analysis)

    base_score + complexity_adjustment + capability_penalty + context_adjustment
  end

  defp base_score(model, :optimize_price) do
    case model.cost do
      %{input: input, output: output} ->
        avg = (input + output) / 2

        cond do
          avg == 0.0 -> 0.0
          true -> :math.log(avg + 1) * 5
        end

      _ ->
        5.0
    end
  end

  defp base_score(model, :optimize_speed) do
    cond do
      MapSet.member?(model.capabilities, :free) -> 1.0
      model.tier_hint == :lightweight -> 2.0
      model.tier_hint == :primary -> 4.0
      true -> 6.0
    end
  end

  defp complexity_adjustment(model, :simple, :optimize_price) do
    if model.tier_hint == :lightweight or MapSet.member?(model.capabilities, :free) do
      -2.0
    else
      3.0
    end
  end

  defp complexity_adjustment(model, :simple, :optimize_speed) do
    if model.tier_hint == :lightweight or MapSet.member?(model.capabilities, :free) do
      -1.5
    else
      1.0
    end
  end

  defp complexity_adjustment(_model, :moderate, _preference), do: 0.0

  defp complexity_adjustment(model, :complex, :optimize_price) do
    if model.tier_hint == :primary do
      -3.0
    else
      2.0
    end
  end

  defp complexity_adjustment(model, :complex, :optimize_speed) do
    cond do
      MapSet.member?(model.capabilities, :reasoning) -> -2.0
      model.tier_hint == :primary -> -1.0
      true -> 1.0
    end
  end

  defp capability_penalty(model, analysis) do
    penalty = 0.0

    penalty =
      if analysis.needs_vision and not MapSet.member?(model.capabilities, :vision) do
        penalty + 100.0
      else
        penalty
      end

    penalty =
      if analysis.needs_audio and not MapSet.member?(model.capabilities, :audio) do
        penalty + 100.0
      else
        penalty
      end

    penalty =
      if analysis.needs_reasoning and not MapSet.member?(model.capabilities, :reasoning) do
        penalty + 5.0
      else
        penalty
      end

    required = analysis.required_capabilities || []

    penalty =
      Enum.reduce(required, penalty, fn cap, acc ->
        if cap in [:chat, :tools] and not MapSet.member?(model.capabilities, cap) do
          acc + 100.0
        else
          acc
        end
      end)

    penalty
  end

  defp context_adjustment(model, analysis) do
    if analysis.needs_large_context do
      case model.context_window do
        nil -> 5.0
        cw when cw >= 100_000 -> -10.0
        cw when cw >= 50_000 -> -3.0
        _ -> 5.0
      end
    else
      0.0
    end
  end
end
