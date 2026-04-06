defmodule AgentEx.Skill.Analyzer do
  @moduledoc """
  Analyzes skill content to determine model tier requirements.

  Uses static analysis of the skill body and metadata to determine what
  model capabilities are needed. This runs at install time and when agents
  create new skills, injecting `model_tier` into the frontmatter if not
  already set.

  ## Model Tiers

  - `:primary` — Needs a capable model: tool use, complex reasoning, multi-step workflows
  - `:lightweight` — Can run on a fast/cheap model: simple lookups, mechanical processes
  - `:any` — No strong preference, works with either

  ## Analysis Signals

  Signals that push toward `:primary`:
  - Tool calls referenced in the body (e.g., tool names, `use_tool`, function calls)
  - Multi-step workflows (numbered steps, decision trees)
  - Complex reasoning language (analyze, evaluate, decompose, synthesize)
  - Delegation/coordination patterns (send_message, marketplace, sub-agent)
  - SOP type with many steps

  Signals that push toward `:lightweight`:
  - Pure reference/documentation content
  - Simple lookup or formatting tasks
  - No tool usage mentioned
  - Short body with no conditional logic
  """

  alias AgentEx.Skill.Parser

  @doc """
  Analyze a parsed skill and return the recommended model tier.

  If the skill already has a non-default `model_tier` set in frontmatter,
  returns that value unchanged. Otherwise, runs static analysis.
  """
  @spec analyze(Parser.parsed_skill()) :: Parser.model_tier()
  def analyze(%{meta: %{model_tier: tier}}) when tier != :any, do: tier

  def analyze(%{meta: meta, body: body}) do
    score = compute_score(meta, body)

    cond do
      score >= 3 -> :primary
      score <= -2 -> :lightweight
      true -> :any
    end
  end

  @doc """
  Analyze a skill and return the tier along with the reasoning signals found.

  Useful for debugging and for the skill-creator to understand why a tier
  was chosen.
  """
  @spec analyze_with_reasons(Parser.parsed_skill()) :: {Parser.model_tier(), [String.t()]}
  def analyze_with_reasons(%{meta: meta, body: body}) do
    {score, reasons} = compute_score_with_reasons(meta, body)

    tier =
      cond do
        score >= 3 -> :primary
        score <= -2 -> :lightweight
        true -> :any
      end

    {tier, reasons}
  end

  @doc """
  Inject `model_tier` into a SKILL.md raw content string if not already present.

  Parses the content, analyzes it, and rewrites the frontmatter with the
  `model_tier` field added. Returns the modified raw content.
  """
  @spec inject_model_tier(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def inject_model_tier(raw_content) do
    case Parser.parse(raw_content) do
      {:ok, parsed} ->
        if has_model_tier_in_raw?(raw_content) do
          {:ok, raw_content}
        else
          tier = analyze(parsed)
          {:ok, insert_tier_into_frontmatter(raw_content, tier)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Scoring ---

  defp compute_score(meta, body) do
    {score, _reasons} = compute_score_with_reasons(meta, body)
    score
  end

  defp compute_score_with_reasons(meta, body) do
    signals = [
      check_type(meta),
      check_tool_references(body),
      check_reasoning_complexity(body),
      check_delegation_patterns(body),
      check_step_count(body),
      check_body_length(body),
      check_reference_only(meta, body)
    ]

    signals
    |> List.flatten()
    |> Enum.reduce({0, []}, fn {delta, reason}, {score, reasons} ->
      {score + delta, [reason | reasons]}
    end)
    |> then(fn {score, reasons} -> {score, Enum.reverse(reasons)} end)
  end

  # SOP type skills tend to be more complex
  defp check_type(%{type: "sop"}), do: [{1, "SOP type (structured workflow)"}]
  defp check_type(_), do: []

  # Tool names and tool-use patterns in the body
  @tool_patterns [
    ~r/\b(search_tools|use_tool|activate_tool|get_tool_schema)\b/,
    ~r/\b(write_file|read_file|list_files)\b/,
    ~r/\b(send_message_to_workspace|spawn_sub_agent)\b/,
    ~r/\b(marketplace_\w+)\b/,
    ~r/\b(create_workspace|workspace_info)\b/,
    ~r/\b(skill_read|skill_install|skill_list)\b/,
    ~r/\b(memory_query|memory_ingest)\b/,
    ~r/\b(set_agent_name|report_status)\b/,
    ~r/`[a-z_]+`\s*(?:tool|—)/
  ]

  defp check_tool_references(body) do
    count =
      Enum.count(@tool_patterns, fn pattern -> Regex.match?(pattern, body) end)

    cond do
      count >= 4 -> [{2, "heavy tool usage (#{count} tool patterns)"}]
      count >= 2 -> [{1, "moderate tool usage (#{count} tool patterns)"}]
      count == 0 -> [{-1, "no tool references"}]
      true -> []
    end
  end

  # Complex reasoning language
  @reasoning_patterns [
    ~r/\b(analyze|evaluate|decompose|synthesize|prioritize)\b/i,
    ~r/\b(trade-?off|decision tree|judgment|nuance)\b/i,
    ~r/\b(if .+ then|depending on|based on context)\b/i,
    ~r/\b(capability check|gap analysis|risk assess)\b/i
  ]

  defp check_reasoning_complexity(body) do
    count =
      Enum.count(@reasoning_patterns, fn pattern -> Regex.match?(pattern, body) end)

    cond do
      count >= 3 -> [{2, "complex reasoning required (#{count} patterns)"}]
      count >= 1 -> [{1, "moderate reasoning (#{count} patterns)"}]
      true -> []
    end
  end

  # Delegation and coordination patterns
  @delegation_patterns [
    ~r/\bdelegate\b/i,
    ~r/\bsub-?task/i,
    ~r/\borchestrat/i,
    ~r/\brouting\b/i,
    ~r/\bcoordinat/i,
    ~r/\bmarketplace\b/i,
    ~r/\bbidding\b/i
  ]

  defp check_delegation_patterns(body) do
    count =
      Enum.count(@delegation_patterns, fn pattern -> Regex.match?(pattern, body) end)

    if count >= 2 do
      [{2, "delegation/coordination patterns (#{count} matches)"}]
    else
      []
    end
  end

  # Number of numbered steps (### N. ...)
  defp check_step_count(body) do
    steps = ~r/^###\s+\d+\./m |> Regex.scan(body) |> length()

    cond do
      steps >= 5 -> [{1, "many steps (#{steps})"}]
      steps == 0 -> [{-1, "no structured steps"}]
      true -> []
    end
  end

  # Very short body suggests simple/reference content
  defp check_body_length(body) do
    len = String.length(body)

    cond do
      len < 200 -> [{-1, "very short body (#{len} chars)"}]
      len > 3000 -> [{1, "substantial body (#{len} chars)"}]
      true -> []
    end
  end

  # Pure reference/documentation skills
  defp check_reference_only(%{type: "skill"}, body) do
    has_tables = Regex.match?(~r/\|.*\|.*\|/, body)
    has_lists = Regex.match?(~r/^- \*\*/m, body)
    no_actions = not Regex.match?(~r/\b(you (MUST|SHOULD|must|should)|call|execute|run)\b/, body)

    if has_tables and has_lists and no_actions do
      [{-2, "reference-only content (tables + lists, no actions)"}]
    else
      []
    end
  end

  defp check_reference_only(_, _), do: []

  # --- Frontmatter injection ---

  defp has_model_tier_in_raw?(content) do
    # Check if model_tier already exists in the frontmatter section
    case String.split(content, ~r/\n---\s*\n/, parts: 2) do
      [frontmatter, _] -> String.contains?(frontmatter, "model_tier:")
      _ -> false
    end
  end

  defp insert_tier_into_frontmatter(content, tier) do
    lines = String.split(content, "\n")

    # Find the closing --- (second occurrence)
    {before_close, from_close} =
      case lines do
        ["---" | rest] ->
          idx = Enum.find_index(rest, &(String.trim(&1) == "---"))

          if idx do
            {["---" | Enum.take(rest, idx)], Enum.drop(rest, idx)}
          else
            {lines, []}
          end

        _ ->
          {lines, []}
      end

    case from_close do
      [] ->
        content

      _ ->
        Enum.join(before_close ++ ["model_tier: #{tier}"] ++ from_close, "\n")
    end
  end
end
