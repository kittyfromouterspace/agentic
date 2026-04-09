defmodule AgentEx.ModelRouter.Selector do
  @moduledoc """
  Scores and ranks catalog models based on an `Analyzer.analysis()` result
  and a user `Preference`.

  Returns an ordered list of `{model, score}` tuples (lowest score first).
  Models with missing required capabilities receive heavy penalties so they
  sink to the bottom but remain available as fallbacks.
  """

  alias AgentEx.LLM.Catalog
  alias AgentEx.ModelRouter.Analyzer
  alias AgentEx.ModelRouter.Preference

  require Logger

  @type ranked_model :: {AgentEx.LLM.Model.t(), float()}

  @doc """
  Analyze a request and return ranked models for the given preference.

  This is the main entry point combining analysis + ranking.
  When `llm_chat` is provided, uses LLM-based analysis; otherwise
  falls back to heuristic analysis.
  """
  @spec select(String.t(), Preference.preference(), keyword()) ::
          {:ok, {AgentEx.LLM.Model.t(), Analyzer.analysis()}} | {:error, term()}
  def select(request, preference, opts \\ []) do
    context_summary = Keyword.get(opts, :context_summary, "")
    session_id = Keyword.get(opts, :session_id)
    llm_chat = Keyword.get(opts, :llm_chat)

    start_time = System.monotonic_time()

    AgentEx.Telemetry.event([:model_router, :selection, :start], %{}, %{
      session_id: session_id,
      preference: preference,
      request_length: String.length(request)
    })

    result =
      case Analyzer.analyze(request,
             context_summary: context_summary,
             llm_chat: llm_chat,
             session_id: session_id
           ) do
        {:ok, analysis} ->
          models = fetch_candidates(analysis)

          ranked =
            models
            |> Enum.map(fn model -> {model, Preference.score(model, preference, analysis)} end)
            |> Enum.sort_by(fn {_model, score} -> score end)

          duration = System.monotonic_time() - start_time

          case ranked do
            [{best, best_score} | _] ->
              Logger.debug(
                "ModelRouter.Selector: selected #{best.provider}/#{best.id} " <>
                  "(complexity: #{analysis.complexity}, preference: #{preference})"
              )

              top3 =
                ranked
                |> Enum.take(3)
                |> Enum.map(fn {m, s} ->
                  %{
                    provider: m.provider,
                    model_id: m.id,
                    label: m.label,
                    score: Float.round(s, 2)
                  }
                end)

              AgentEx.Telemetry.event(
                [:model_router, :selection, :stop],
                %{
                  duration: duration,
                  candidate_count: length(ranked),
                  best_score: Float.round(best_score, 2)
                },
                %{
                  session_id: session_id,
                  preference: preference,
                  complexity: analysis.complexity,
                  selected_provider: best.provider,
                  selected_model_id: best.id,
                  selected_label: best.label,
                  needs_vision: analysis.needs_vision,
                  needs_reasoning: analysis.needs_reasoning,
                  needs_large_context: analysis.needs_large_context,
                  top3: top3
                }
              )

              {:ok, {best, analysis}}

            [] ->
              AgentEx.Telemetry.event(
                [:model_router, :selection, :stop],
                %{
                  duration: duration,
                  candidate_count: 0
                },
                %{
                  session_id: session_id,
                  preference: preference,
                  error: :no_models_available
                }
              )

              {:error, :no_models_available}
          end
      end

    result
  end

  @doc """
  Rank all candidate models for a given analysis and preference.

  Returns a list of `{model, score}` tuples sorted by score ascending.
  """
  @spec rank(Analyzer.analysis(), Preference.preference()) :: [ranked_model()]
  def rank(analysis, preference) do
    models = fetch_candidates(analysis)

    models
    |> Enum.map(fn model -> {model, Preference.score(model, preference, analysis)} end)
    |> Enum.sort_by(fn {_model, score} -> score end)
  end

  @doc "Get the top N ranked models."
  @spec top(Analyzer.analysis(), Preference.preference(), pos_integer()) :: [ranked_model()]
  def top(analysis, preference, n \\ 3) do
    analysis
    |> rank(preference)
    |> Enum.take(n)
  end

  defp fetch_candidates(analysis) do
    required = analysis.required_capabilities || [:chat]

    base = Catalog.find(has: required)

    if analysis.needs_vision do
      base
    else
      base ++ Catalog.find(has: [:chat])
    end
    |> Enum.uniq_by(fn m -> {m.provider, m.id} end)
  end
end
