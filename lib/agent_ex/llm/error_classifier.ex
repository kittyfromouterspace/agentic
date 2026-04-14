defmodule AgentEx.LLM.ErrorClassifier do
  @moduledoc """
  Unified error classification combining three sources:

  1. Provider-specific override via `Provider.classify_http_error/3`
  2. HTTP status code baseline lookup
  3. Pattern-based fallback via `ErrorPatterns.classify_message/1`
  4. Always test for `:context_overflow` separately (can happen on any status)

  If none match, falls through to `:permanent`.
  """

  alias AgentEx.LLM.{Error, ErrorPatterns}

  @type classification :: Error.classification()

  @doc """
  Classify an error from HTTP status, body, and headers.

  `provider` is the provider module (e.g. `AgentEx.LLM.Provider.Groq`).
  When the provider implements the optional `classify_http_error/3`
  callback, its result takes precedence over the generic baseline.
  """
  @spec classify(non_neg_integer() | nil, term(), term(), module() | nil) :: {atom(), term()}
  def classify(status, body, headers, provider \\ nil) do
    message = stringify_body(body)

    provider_result =
      if provider && function_exported?(provider, :classify_http_error, 3) do
        provider.classify_http_error(status, body, headers)
      else
        :default
      end

    result =
      case provider_result do
        {classification, _retry_after_ms} = result when is_atom(classification) ->
          result

        classification when is_atom(classification) and classification != :default ->
          {classification, nil}

        :default ->
          classify_default(status, message)
      end

    case result do
      {classification, retry_after} ->
        if classification == :context_overflow do
          {:context_overflow, retry_after}
        else
          context_overflow = ErrorPatterns.classify_context_overflow(String.downcase(message))
          if context_overflow, do: {:context_overflow, nil}, else: result
        end

      classification ->
        context_overflow = ErrorPatterns.classify_context_overflow(String.downcase(message))
        if context_overflow, do: {:context_overflow, nil}, else: {classification, nil}
    end
  end

  defp classify_default(status, message) do
    baseline = status_baseline(status)

    case baseline do
      nil ->
        case ErrorPatterns.classify_message(message) do
          nil -> :permanent
          classification -> {classification, nil}
        end

      classification ->
        {classification, nil}
    end
  end

  # Status code → classification baseline table
  defp status_baseline(402), do: :billing
  defp status_baseline(401), do: :auth
  defp status_baseline(403), do: :auth_permanent
  defp status_baseline(404), do: :model_not_found
  defp status_baseline(408), do: :timeout
  defp status_baseline(410), do: :session_expired
  defp status_baseline(429), do: :rate_limit

  defp status_baseline(status) when is_integer(status) and status >= 500 and status < 600 do
    :transient
  end

  defp status_baseline(status) when is_integer(status) and status >= 400 and status < 500 do
    :permanent
  end

  defp status_baseline(_), do: nil

  defp stringify_body(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp stringify_body(body) when is_binary(body), do: body
  defp stringify_body(other), do: inspect(other, limit: 200)
end
