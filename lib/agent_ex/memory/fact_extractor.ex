defmodule AgentEx.Memory.FactExtractor do
  @moduledoc """
  Pure, deterministic fact extraction from tool results and LLM responses.

  Uses regex-based pattern matching to extract structured facts — NO LLM calls,
  NO GenServer. Must be fast enough to run synchronously after every tool call.

  Each fact is a map with:
  - `entity` — the subject (file path, tool name, concept)
  - `relation` — the predicate (mentions, produced_error, succeeded, decided, etc.)
  - `value` — the object (the path, error message, decision text, etc.)
  - `confidence` — 0.0 to 1.0
  - `source_turn` — which conversation turn produced this fact
  """

  @type fact :: %{
          entity: String.t(),
          relation: String.t(),
          value: String.t(),
          confidence: float(),
          source_turn: integer()
        }

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Extract facts from a tool result.

  Takes the tool name, result string, and current turn number.
  """
  @spec extract_from_tool_result(String.t(), String.t(), integer()) :: [fact()]
  def extract_from_tool_result(tool_name, result, turn) when is_binary(result) do
    facts = []

    # Tool outcome fact
    facts =
      if is_error_result?(result) do
        [
          %{
            entity: tool_name,
            relation: "produced_error",
            value: truncate(extract_error_summary(result), 200),
            confidence: 0.9,
            source_turn: turn
          }
          | facts
        ]
      else
        [
          %{
            entity: tool_name,
            relation: "succeeded",
            value: truncate(first_line(result), 120),
            confidence: 0.8,
            source_turn: turn
          }
          | facts
        ]
      end

    # File paths mentioned in the result
    facts = facts ++ extract_file_paths(result, turn)

    # Error patterns
    facts = facts ++ extract_errors(result, turn)

    facts
  end

  def extract_from_tool_result(_tool_name, _result, _turn), do: []

  @doc """
  Extract facts from an LLM response text.

  Looks for decisions, file paths, and error mentions.
  """
  @spec extract_from_response(String.t(), integer()) :: [fact()]
  def extract_from_response(text, turn) when is_binary(text) do
    facts = []

    # File paths
    facts = facts ++ extract_file_paths(text, turn)

    # Decisions / commitments
    facts = facts ++ extract_decisions(text, turn)

    facts
  end

  def extract_from_response(_text, _turn), do: []

  # ── Private: Extractors ──────────────────────────────────────────────

  @file_path_regex ~r"(?:^|[\s\"'`(])(/[a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+)"
  @relative_path_regex ~r"(?:^|[\s\"'`(])([a-zA-Z0-9_][a-zA-Z0-9_./+-]*\.[a-zA-Z]{1,10})"

  defp extract_file_paths(text, turn) do
    absolute =
      @file_path_regex
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()

    relative =
      @relative_path_regex
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.filter(&likely_file_path?/1)

    (absolute ++ relative)
    |> Enum.uniq()
    |> Enum.take(10)
    |> Enum.map(fn path ->
      %{
        entity: path,
        relation: "mentioned",
        value: "file path",
        confidence: 0.7,
        source_turn: turn
      }
    end)
  end

  @decision_patterns [
    ~r"(?:I will|I'll|Let's|Let me|I'm going to|I need to|I should)\s+(.{10,120})"i,
    ~r"(?:The (?:solution|fix|approach|plan) is)\s+(.{10,120})"i
  ]

  defp extract_decisions(text, turn) do
    @decision_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.take(3)
    |> Enum.map(fn decision ->
      %{
        entity: "agent",
        relation: "decided",
        value: truncate(String.trim(decision), 150),
        confidence: 0.6,
        source_turn: turn
      }
    end)
  end

  @error_patterns [
    ~r"(?:error|Error|ERROR)[:\s]+(.{5,200})"m,
    ~r"(?:\*\*|`)((?:CompileError|RuntimeError|ArgumentError|KeyError|FunctionClauseError|MatchError)[^`*]*)"m,
    ~r"(?:failed|Failed|FAILED)[:\s]+(.{5,150})"m,
    ~r"(?:exception|Exception)[:\s]+(.{5,150})"m
  ]

  defp extract_errors(text, turn) do
    @error_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.take(5)
    |> Enum.map(fn error_text ->
      %{
        entity: "execution",
        relation: "error",
        value: truncate(String.trim(error_text), 200),
        confidence: 0.85,
        source_turn: turn
      }
    end)
  end

  # ── Private: Helpers ─────────────────────────────────────────────────

  defp is_error_result?(text) do
    String.contains?(text, ["Tool error:", "error:", "Error:", "failed", "Failed", "[exit code:"])
  end

  defp extract_error_summary(text) do
    text
    |> String.split("\n")
    |> Enum.find(fn line ->
      String.contains?(line, ["error", "Error", "failed", "Failed"])
    end)
    |> case do
      nil -> first_line(text)
      line -> String.trim(line)
    end
  end

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first("")
    |> String.trim()
  end

  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end

  @known_extensions ~w(.ex .exs .erl .hrl .js .ts .tsx .jsx .py .rb .go .rs .java .c .h .cpp .hpp .css .scss .html .json .yaml .yml .toml .md .txt .sh .bash .fish .sql .xml .svelte .vue .lua .zig .nim .swift .kt .scala)

  defp likely_file_path?(path) do
    ext = Path.extname(path)
    # Must have a known extension and contain a slash or be a simple filename
    ext in @known_extensions and not String.contains?(path, " ")
  end

  # ── LLM-Assisted Extraction ────────────────────────────────────────

  @doc """
  Check if the current turn qualifies for LLM-assisted fact extraction.

  Heuristics:
  - 3+ tool calls in the turn
  - Response contains decision language
  - Agent used memory_write
  """
  @spec qualifies_for_llm_extraction?(list(), String.t(), integer()) :: boolean()
  def qualifies_for_llm_extraction?(tool_names, response_text, turn) do
    # Rate limit: max 1 LLM extraction per 5 turns
    if rem(turn, 5) != 0 and not has_decision_language?(response_text) do
      false
    else
      length(tool_names) >= 3 or
        "memory_write" in tool_names or
        has_decision_language?(response_text)
    end
  end

  @decision_language_patterns [
    ~r/I decided/i,
    ~r/The best approach/i,
    ~r/Going with/i,
    ~r/We should use/i,
    ~r/The solution is/i,
    ~r/After investigating/i,
    ~r/Root cause/i,
    ~r/The issue was/i
  ]

  defp has_decision_language?(text) when is_binary(text) do
    Enum.any?(@decision_language_patterns, &Regex.match?(&1, text))
  end

  defp has_decision_language?(_), do: false

  @doc """
  Extract facts using an LLM call. Async, non-blocking.

  Accepts an optional `llm_chat` function as the 4th argument. If nil, returns `[]`.
  The function should accept a params map and return `{:ok, response}` or `{:error, reason}`.

  Returns a list of fact maps with optional :supersedes field.
  """
  @spec extract_with_llm(String.t(), list(), integer(), function() | nil) :: [fact()]
  def extract_with_llm(response_text, tool_summaries, turn, llm_chat \\ nil)

  def extract_with_llm(_response_text, _tool_summaries, _turn, nil), do: []

  def extract_with_llm(response_text, tool_summaries, turn, llm_chat) do
    prompt_template = read_prompt_template()

    tools_summary =
      Enum.map_join(tool_summaries, "\n", fn {name, result_preview} ->
        "- #{name}: #{truncate(result_preview, 200)}"
      end)

    prompt =
      prompt_template
      |> String.replace("{tools_summary}", tools_summary)
      |> String.replace("{response_text}", truncate(response_text, 2000))

    params = %{
      "messages" => [
        %{"role" => "user", "content" => prompt}
      ],
      "tools" => [],
      "session_id" => nil,
      "user_id" => nil,
      "model_tier" => "lightweight"
    }

    case llm_chat.(params) do
      {:ok, response} ->
        text =
          (response["content"] || [])
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", &(&1["text"] || ""))

        parse_llm_facts(text, turn)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp read_prompt_template do
    path = Application.app_dir(:agent_ex, "priv/prompts/fact_extraction.md")

    case File.read(path) do
      {:ok, content} ->
        content

      _ ->
        "Extract structured facts as JSON from the following agent turn.\n\n{tools_summary}\n\n{response_text}"
    end
  end

  defp parse_llm_facts(text, turn) do
    # Extract JSON array from response (may be wrapped in markdown code block)
    json_text =
      case Regex.run(~r/\[[\s\S]*\]/, text) do
        [match] -> match
        _ -> "[]"
      end

    case Jason.decode(json_text) do
      {:ok, facts} when is_list(facts) ->
        Enum.map(facts, fn f ->
          base = %{
            entity: f["entity"] || "unknown",
            relation: f["relation"] || "noted",
            value: truncate(f["value"] || "", 200),
            confidence: 0.85,
            source_turn: turn
          }

          if f["supersedes"] do
            Map.put(base, :supersedes, f["supersedes"])
          else
            base
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end
end
