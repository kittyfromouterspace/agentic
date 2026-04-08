defmodule AgentEx.LLM.UsageWindow do
  @moduledoc """
  A single rate-limit / quota window for one provider. Anthropic has
  rolling 5-hour and 7-day windows; OpenRouter has a single credit
  pool; Groq has per-minute RPM caps. They all map to this struct.
  """

  @type t :: %__MODULE__{
          label: String.t(),
          used: number() | nil,
          limit: number() | nil,
          unit: :tokens | :requests | :usd | atom(),
          reset_at: integer() | nil
        }

  defstruct label: nil,
            used: nil,
            limit: nil,
            unit: :tokens,
            reset_at: nil
end
