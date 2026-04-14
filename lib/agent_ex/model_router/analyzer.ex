defmodule AgentEx.ModelRouter.Analyzer do
  @moduledoc """
  Analyzes a user request using a fast, ideally free model to determine
  complexity, required capabilities (vision, audio, reasoning, etc.),
  and context requirements.

  The analysis result is then used by `AgentEx.ModelRouter.Selector` to
  pick the best model based on user preferences.
  """

  alias AgentEx.LLM.Catalog

  require Logger

  @type complexity :: :simple | :moderate | :complex

  @type analysis :: %{
          complexity: complexity(),
          required_capabilities: [atom()],
          needs_vision: boolean(),
          needs_audio: boolean(),
          needs_reasoning: boolean(),
          needs_large_context: boolean(),
          estimated_input_tokens: non_neg_integer(),
          explanation: String.t()
        }

  @doc """
  Analyze a user request for complexity and capability requirements.

  Uses the cheapest available model (preferring free models) to classify
  the request. Falls back to heuristic analysis if no model is available.
  """
  @spec analyze(String.t(), keyword()) :: {:ok, analysis()} | {:error, term()}
  def analyze(request, opts \\ []) do
    context_summary = Keyword.get(opts, :context_summary, "")
    session_id = Keyword.get(opts, :session_id)
    llm_chat = Keyword.get(opts, :llm_chat)

    start_time = System.monotonic_time()

    method = if llm_chat, do: :llm, else: :heuristic

    AgentEx.Telemetry.event([:model_router, :analysis, :start], %{}, %{
      method: method,
      session_id: session_id,
      request_length: String.length(request)
    })

    result =
      if llm_chat do
        analyze_via_llm(request, context_summary, llm_chat, session_id)
      else
        analyze_heuristic(request)
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, analysis} ->
        AgentEx.Telemetry.event(
          [:model_router, :analysis, :stop],
          %{duration: duration},
          %{
            method: method,
            session_id: session_id,
            complexity: analysis.complexity,
            needs_vision: analysis.needs_vision,
            needs_audio: analysis.needs_audio,
            needs_reasoning: analysis.needs_reasoning,
            needs_large_context: analysis.needs_large_context,
            estimated_input_tokens: analysis.estimated_input_tokens,
            required_capabilities: analysis.required_capabilities
          }
        )

        {:ok, analysis}

      {:error, reason} ->
        Logger.warning("ModelRouter.Analyzer: analysis failed: #{inspect(reason)}")

        AgentEx.Telemetry.event(
          [:model_router, :analysis, :stop],
          %{duration: duration},
          %{method: method, session_id: session_id, error: inspect(reason)}
        )

        {:error, reason}
    end
  end

  defp analyze_via_llm(request, context_summary, llm_chat, session_id) do
    prompt = build_analysis_prompt(request, context_summary)

    messages = [
      %{
        "role" => "user",
        "content" => prompt
      }
    ]

    params = %{
      "messages" => messages,
      "model_tier" => "lightweight",
      "temperature" => 0.1,
      "max_tokens" => 500,
      "internal" => true
    }

    case llm_chat.(params) do
      {:ok, response} ->
        content = response.content || []

        text =
          content
          |> Enum.filter(&(&1.type == :text))
          |> Enum.map_join(& &1.text)
          |> String.trim()

        parse_analysis(text)

      {:error, reason} ->
        Logger.warning("ModelRouter.Analyzer: LLM analysis failed: #{inspect(reason)}")

        AgentEx.Telemetry.event([:model_router, :analysis, :fallback], %{}, %{
          session_id: session_id,
          from: :llm,
          to: :heuristic,
          reason: inspect(reason)
        })

        analyze_heuristic(request)
    end
  end

  defp build_analysis_prompt(request, context_summary) do
    :code.priv_dir(:agent_ex)
    |> Path.join("prompts/model_analysis.md")
    |> File.read!()
    |> String.replace("{request}", request)
    |> String.replace("{context_summary}", context_summary || "No additional context provided.")
  end

  defp parse_analysis(text) do
    case extract_json(text) do
      {:ok, data} when is_map(data) ->
        {:ok, normalize_analysis(data)}

      _ ->
        Logger.warning("ModelRouter.Analyzer: failed to parse LLM analysis response")

        AgentEx.Telemetry.event([:model_router, :analysis, :parse_failure], %{}, %{})

        {:ok, heuristic_from_text(text)}
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [match] -> Jason.decode(match)
      _ -> :no_match
    end
  end

  defp normalize_analysis(data) do
    %{
      complexity: parse_complexity(data["complexity"]),
      required_capabilities: parse_capabilities(data),
      needs_vision: data["needs_vision"] == true,
      needs_audio: data["needs_audio"] == true,
      needs_reasoning: data["needs_reasoning"] == true,
      needs_large_context: data["needs_large_context"] == true,
      estimated_input_tokens: parse_tokens(data["estimated_input_tokens"]),
      explanation: data["explanation"] || ""
    }
  end

  defp parse_complexity("simple"), do: :simple
  defp parse_complexity("moderate"), do: :moderate
  defp parse_complexity("complex"), do: :complex
  defp parse_complexity(_), do: :moderate

  defp parse_capabilities(data) do
    base = [:chat]

    base =
      if data["needs_reasoning"] == true or data["complexity"] == "complex" do
        [:reasoning | base]
      else
        base
      end

    base =
      if data["needs_vision"] == true do
        [:vision | base]
      else
        base
      end

    Enum.uniq(base)
  end

  defp parse_tokens(val) when is_integer(val) and val > 0, do: val

  defp parse_tokens(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> 500
    end
  end

  defp parse_tokens(_), do: 500

  defp heuristic_from_text(text) do
    lower = String.downcase(text)

    %{
      complexity: :moderate,
      required_capabilities: [:chat],
      needs_vision: String.contains?(lower, "image") or String.contains?(lower, "screenshot"),
      needs_audio: String.contains?(lower, "audio") or String.contains?(lower, "speech"),
      needs_reasoning: false,
      needs_large_context: false,
      estimated_input_tokens: 500,
      explanation: "Heuristic fallback analysis"
    }
  end

  @doc """
  Pure heuristic analysis — no LLM call. Used as fallback when no
  lightweight model is available or when the caller wants zero-latency analysis.
  """
  @spec analyze_heuristic(String.t()) :: {:ok, analysis()}
  def analyze_heuristic(request) do
    lower = String.downcase(request)
    length = String.length(request)

    has_image_keywords =
      Enum.any?(
        ~w(image screenshot photo picture diagram chart visual),
        &String.contains?(lower, &1)
      )

    has_audio_keywords =
      Enum.any?(~w(audio speech sound voice music transcript), &String.contains?(lower, &1))

    has_complex_keywords =
      Enum.any?(
        ~w(refactor architecture redesign migrate optimize analyze),
        &String.contains?(lower, &1)
      )

    has_reasoning_keywords =
      Enum.any?(~w(why explain reason logic proof deduce calculate), &String.contains?(lower, &1))

    has_tool_keywords =
      Enum.any?(~w(read write file execute run build test deploy), &String.contains?(lower, &1))

    complexity =
      cond do
        length < 50 and not has_complex_keywords and not has_reasoning_keywords -> :simple
        has_complex_keywords or has_reasoning_keywords or length > 500 -> :complex
        true -> :moderate
      end

    capabilities = [:chat]
    capabilities = if has_tool_keywords, do: [:tools | capabilities], else: capabilities
    capabilities = if has_reasoning_keywords, do: [:reasoning | capabilities], else: capabilities
    capabilities = if has_image_keywords, do: [:vision | capabilities], else: capabilities

    estimated_tokens = max(100, div(length * 4, 3))

    {:ok,
     %{
       complexity: complexity,
       required_capabilities: Enum.uniq(capabilities),
       needs_vision: has_image_keywords,
       needs_audio: has_audio_keywords,
       needs_reasoning: has_reasoning_keywords,
       needs_large_context: length > 5000,
       estimated_input_tokens: estimated_tokens,
       explanation: "Heuristic analysis based on request content"
     }}
  end

  @doc "Find the cheapest available model suitable for analysis."
  def find_analysis_model do
    candidates =
      Catalog.find(has: :chat)
      |> Enum.filter(fn m ->
        MapSet.member?(m.capabilities, :free) or
          m.tier_hint == :lightweight or
          (m.cost != nil and m.cost[:input] != nil and m.cost[:input] < 0.5)
      end)
      |> Enum.sort_by(&analysis_model_priority/1)

    List.first(candidates)
  end

  defp analysis_model_priority(model) do
    cond do
      MapSet.member?(model.capabilities, :free) -> 0
      model.tier_hint == :lightweight -> 1
      model.cost[:input] < 0.1 -> 2
      model.cost[:input] < 0.5 -> 3
      true -> 4
    end
  end
end
