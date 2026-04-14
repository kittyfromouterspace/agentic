defmodule AgentEx.LLM.ErrorPatterns do
  @moduledoc """
  Generic pattern tables for classifying LLM provider errors from
  response body text. Ported from openclaw's `failover-matches.ts`.

  Each `classify_* /1` function tests a lowercased message against a
  set of string/regex patterns. Returns the matching classification
  atom or `nil`.

  `classify_message/1` runs all classifiers in priority order and
  returns the first match.
  """

  alias AgentEx.LLM.Error

  @type classification :: Error.classification()

  @doc """
  Run all pattern classifiers against `message` in priority order.
  Returns the first matching classification, or `nil`.

  Context overflow is tested separately (last) because it's the one
  classification that doesn't trigger failover — it triggers
  compaction instead. We still detect it here so the caller can
  route it appropriately.
  """
  @spec classify_message(String.t()) :: classification() | nil
  def classify_message(message) when is_binary(message) do
    lowered = String.downcase(message)

    classify_billing(lowered) ||
      classify_auth_permanent(lowered) ||
      classify_rate_limit(lowered) ||
      classify_overloaded(lowered) ||
      classify_timeout(lowered) ||
      classify_auth(lowered) ||
      classify_format(lowered) ||
      classify_model_not_found(lowered) ||
      classify_session_expired(lowered) ||
      classify_context_overflow(lowered)
  end

  def classify_message(_), do: nil

  @doc "Classify rate-limiting errors from a lowered message string."
  @spec classify_rate_limit(String.t()) :: :rate_limit | nil
  def classify_rate_limit(lowered) when is_binary(lowered) do
    cond do
      regex_match?(lowered, ~r/rate[_ ]limit|too many requests|429/) ->
        :rate_limit

      regex_match?(lowered, ~r/too many (?:concurrent )?requests/) ->
        :rate_limit

      regex_match?(lowered, ~r/throttling(?:exception)?/) ->
        :rate_limit

      contains_any?(lowered, [
        "model_cooldown",
        "exceeded your current quota",
        "resource has been exhausted",
        "quota exceeded",
        "resource_exhausted",
        "throttlingexception",
        "throttled",
        "throttling",
        "usage limit"
      ]) ->
        :rate_limit

      regex_match?(lowered, ~r/\btpm\b/) ->
        :rate_limit

      contains_any?(lowered, [
        "tokens per minute",
        "tokens per day"
      ]) ->
        :rate_limit

      true ->
        nil
    end
  end

  @doc "Classify service-overloaded errors from a lowered message string."
  @spec classify_overloaded(String.t()) :: :overloaded | nil
  def classify_overloaded(lowered) when is_binary(lowered) do
    cond do
      regex_match?(lowered, ~r/overloaded_error|"type"\s*:\s*"overloaded_error"/) ->
        :overloaded

      contains_any?(lowered, [
        "overloaded",
        "high demand"
      ]) ->
        :overloaded

      regex_match?(lowered, ~r/service[_ ]unavailable.*(?:overload|capacity|high[_ ]demand)/) ->
        :overloaded

      true ->
        nil
    end
  end

  @doc "Classify billing/payment errors from a lowered message string."
  @spec classify_billing(String.t()) :: :billing | nil
  def classify_billing(lowered) when is_binary(lowered) do
    cond do
      regex_match?(lowered, ~r/["']?(?:status|code)["']?\s*[:=]\s*402\b/) ->
        :billing

      contains_any?(lowered, [
        "payment required",
        "insufficient credits",
        "insufficient_quota",
        "credit balance",
        "plans & billing",
        "insufficient balance",
        "insufficient usd or diem balance"
      ]) ->
        :billing

      regex_match?(lowered, ~r/requires?\s+more\s+credits/) ->
        :billing

      regex_match?(lowered, ~r/out of extra usage/) ->
        :billing

      regex_match?(lowered, ~r/draw from your extra usage/) ->
        :billing

      true ->
        nil
    end
  end

  @doc "Classify permanent auth errors (revoked keys, disabled accounts) from a lowered message string."
  @spec classify_auth_permanent(String.t()) :: :auth_permanent | nil
  def classify_auth_permanent(lowered) when is_binary(lowered) do
    cond do
      regex_match?(lowered, ~r/api[_ ]?key[_ ]?(?:revoked|deactivated|deleted)/) ->
        :auth_permanent

      contains_any?(lowered, [
        "key has been disabled",
        "key has been revoked",
        "account has been deactivated",
        "not allowed for this organization"
      ]) ->
        :auth_permanent

      true ->
        nil
    end
  end

  @doc "Classify transient auth errors (invalid key, expired token) from a lowered message string."
  @spec classify_auth(String.t()) :: :auth | nil
  def classify_auth(lowered) when is_binary(lowered) do
    cond do
      regex_match?(lowered, ~r/invalid[_ ]?api[_ ]?key/) ->
        :auth

      regex_match?(lowered, ~r/could not (?:authenticate|validate).*(?:api[_ ]?key|credentials)/) ->
        :auth

      contains_any?(lowered, [
        "permission_error",
        "incorrect api key",
        "invalid token",
        "authentication",
        "re-authenticate",
        "oauth token refresh failed",
        "unauthorized",
        "forbidden",
        "access denied",
        "insufficient permissions"
      ]) ->
        :auth

      regex_match?(lowered, ~r/missing scopes?:/) ->
        :auth

      contains_any?(lowered, [
        "expired",
        "token has expired"
      ]) ->
        :auth

      regex_match?(lowered, ~r/\b401\b/) ->
        :auth

      regex_match?(lowered, ~r/\b403\b/) ->
        :auth

      contains_any?(lowered, [
        "no credentials found",
        "no api key found"
      ]) ->
        :auth

      true ->
        nil
    end
  end

  @doc "Classify timeout and network errors from a lowered message string."
  @spec classify_timeout(String.t()) :: :timeout | nil
  def classify_timeout(lowered) when is_binary(lowered) do
    cond do
      contains_any?(lowered, [
        "timeout",
        "timed out",
        "deadline exceeded",
        "context deadline exceeded",
        "connection error",
        "network error",
        "network request failed",
        "fetch failed",
        "socket hang up"
      ]) ->
        :timeout

      regex_match?(lowered, ~r/\beconn(?:refused|reset|aborted)\b/) ->
        :timeout

      regex_match?(lowered, ~r/\benetunreach\b/) ->
        :timeout

      regex_match?(lowered, ~r/\behostunreach\b/) ->
        :timeout

      regex_match?(lowered, ~r/\bhostdown\b/) ->
        :timeout

      regex_match?(lowered, ~r/\benetreset\b/) ->
        :timeout

      regex_match?(lowered, ~r/\betimedout\b/) ->
        :timeout

      regex_match?(lowered, ~r/\besockettimedout\b/) ->
        :timeout

      regex_match?(lowered, ~r/\bepipe\b/) ->
        :timeout

      regex_match?(lowered, ~r/\benotfound\b/) ->
        :timeout

      regex_match?(lowered, ~r/\beai_again\b/) ->
        :timeout

      regex_match?(lowered, ~r/\boperation was aborted\b/) ->
        :timeout

      regex_match?(lowered, ~r/\bstream (?:was )?(?:closed|aborted)\b/) ->
        :timeout

      true ->
        nil
    end
  end

  @doc "Classify bad-request format errors from a lowered message string."
  @spec classify_format(String.t()) :: :format | nil
  def classify_format(lowered) when is_binary(lowered) do
    cond do
      contains_any?(lowered, [
        "string should match pattern",
        "tool_use.id",
        "tool_use_id",
        "invalid request format"
      ]) ->
        :format

      regex_match?(lowered, ~r/tool call id was.*must be/) ->
        :format

      true ->
        nil
    end
  end

  @doc "Classify model-not-found errors from a lowered message string."
  @spec classify_model_not_found(String.t()) :: :model_not_found | nil
  def classify_model_not_found(lowered) when is_binary(lowered) do
    cond do
      contains_any?(lowered, [
        "model_is_deactivated",
        "model not found",
        "model does not exist"
      ]) ->
        :model_not_found

      true ->
        nil
    end
  end

  @doc "Classify session-expired errors from a lowered message string."
  @spec classify_session_expired(String.t()) :: :session_expired | nil
  def classify_session_expired(lowered) when is_binary(lowered) do
    cond do
      regex_match?(lowered, ~r/\bsession.*expired\b/) ->
        :session_expired

      true ->
        nil
    end
  end

  @doc """
  Classify context-overflow errors from a lowered message string.

  Uses two-pass detection: first explicit patterns, then a generic
  two-keyword heuristic.
  """
  @spec classify_context_overflow(String.t()) :: :context_overflow | nil
  def classify_context_overflow(lowered) when is_binary(lowered) do
    cond do
      regex_match?(
        lowered,
        ~r/\binput token count exceeds the maximum number of input tokens\b/
      ) ->
        :context_overflow

      regex_match?(lowered, ~r/\binput is too long for this model\b/) ->
        :context_overflow

      regex_match?(
        lowered,
        ~r/\binput exceeds the maximum number of tokens\b/
      ) ->
        :context_overflow

      regex_match?(lowered, ~r/\bollama error:\s*context length exceeded/) ->
        :context_overflow

      regex_match?(
        lowered,
        ~r/\btotal tokens?.*exceeds? (?:the )?(?:model(?:'s)? )?(?:max|maximum|limit)/
      ) ->
        :context_overflow

      regex_match?(
        lowered,
        ~r/\binput (?:is )?too long for (?:the )?model\b/
      ) ->
        :context_overflow

      context_overflow_heuristic?(lowered) ->
        :context_overflow

      true ->
        nil
    end
  end

  defp context_overflow_heuristic?(lowered) do
    left =
      regex_match?(
        lowered,
        ~r/\b(?:context|window|prompt|token|tokens|input|request|model)\b/
      )

    right =
      regex_match?(
        lowered,
        ~r/\b(?:too\s+(?:large|long|many)|exceed(?:s|ed|ing)?|overflow|limit|maximum|max)\b/
      )

    left and right
  end

  # --- helpers ---

  defp regex_match?(str, regex) do
    Regex.match?(regex, str)
  end

  defp contains_any?(str, patterns) when is_binary(str) and is_list(patterns) do
    Enum.any?(patterns, &String.contains?(str, &1))
  end
end
