defmodule AgentEx.LLM.Usage do
  @moduledoc """
  Provider quota / spend snapshot.

  Returned by `Provider.fetch_usage/1` and cached by
  `AgentEx.LLM.UsageManager`. Different providers expose different
  shapes — some have rolling rate-limit windows (Anthropic 5h/7d),
  some have credit balances (OpenRouter), some have RPM caps (Groq).
  This struct accommodates all of them via a list of `%UsageWindow{}`s
  plus an optional `:credits` map.
  """

  alias AgentEx.LLM.UsageWindow

  @type t :: %__MODULE__{
          provider: atom(),
          label: String.t(),
          plan: String.t() | nil,
          windows: [UsageWindow.t()],
          credits: %{used: float(), limit: float()} | nil,
          error: String.t() | nil,
          fetched_at: integer() | nil
        }

  defstruct provider: nil,
            label: nil,
            plan: nil,
            windows: [],
            credits: nil,
            error: nil,
            fetched_at: nil
end
