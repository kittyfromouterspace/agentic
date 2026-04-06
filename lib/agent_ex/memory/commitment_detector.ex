defmodule AgentEx.Memory.CommitmentDetector do
  @moduledoc """
  Detects unfulfilled action commitments in agent responses.

  When the LLM says "I'll check that" or "Let me look into it" but returns
  end_turn without using any tools, the agent has made a promise it didn't keep.
  This module detects such patterns so the session can schedule a follow-up.
  """

  @action_verbs "check|look|search|find|browse|fetch|read|review|investigate|examine|explore|open|visit|grab|run|try|get|analyze|dig into|take a look|pull up|go through|set up|configure|install"

  @commitment_patterns [
    ~r/\blet me\s+(?:#{@action_verbs})\b/i,
    ~r/\bI'll\s+(?:#{@action_verbs})\b/i,
    ~r/\bI will\s+(?:#{@action_verbs})\b/i,
    ~r/\bI'm going to\s+(?:#{@action_verbs})\b/i,
    ~r/\b(?:one moment|give me a (?:moment|second|sec)|hold on|just a moment)\b/i
  ]

  @negative_patterns [
    ~r/\blet me know\b/i,
    ~r/\bfeel free to\b/i,
    ~r/\bwould you like me to\b/i,
    ~r/\bif you'd like me to\b/i,
    ~r/\bdo you want me to\b/i
  ]

  @doc "Returns true if the text contains action commitments suggesting the agent intended to use tools but didn't."
  @spec commitment_detected?(String.t() | nil) :: boolean()
  def commitment_detected?(text) when is_binary(text) and text != "" do
    has_commitment = Enum.any?(@commitment_patterns, &Regex.match?(&1, text))
    only_negative = has_commitment and all_matches_are_negative?(text)
    has_commitment and not only_negative
  end

  def commitment_detected?(_), do: false

  @doc "Extracts the first commitment phrase from the text. Returns nil if no commitment is found."
  @spec extract_commitment(String.t() | nil) :: String.t() | nil
  def extract_commitment(text) when is_binary(text) and text != "" do
    Enum.find_value(@commitment_patterns, fn pattern ->
      case Regex.run(pattern, text) do
        [match | _] ->
          if negative_match?(match), do: nil, else: match

        nil ->
          nil
      end
    end)
  end

  def extract_commitment(_), do: nil

  defp all_matches_are_negative?(text) do
    @commitment_patterns
    |> Enum.flat_map(fn pattern ->
      case Regex.scan(pattern, text) do
        [] -> []
        matches -> Enum.map(matches, &hd/1)
      end
    end)
    |> Enum.all?(&negative_match?/1)
  end

  defp negative_match?(match) do
    Enum.any?(@negative_patterns, &Regex.match?(&1, match))
  end
end
