defmodule Agentic.LLM.Provider.Kimi do
  @moduledoc """
  Catalog-only Provider wrapper for Kimi Code CLI. Kimi serves
  Moonshot's K2 family natively, plus optional routing to other
  providers via its config.
  """

  use Agentic.LLM.Provider.CodingAgentBase,
    id: :kimi,
    cli_name: "kimi",
    label: "Kimi Code",
    model_overrides: [
      {"moonshot/k2", "Kimi K2", :primary, 200_000},
      {"moonshot/k2-thinking", "Kimi K2 Thinking", :primary, 200_000}
    ]
end
