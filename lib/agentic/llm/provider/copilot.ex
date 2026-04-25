defmodule Agentic.LLM.Provider.Copilot do
  @moduledoc "Catalog-only Provider wrapper for GitHub Copilot CLI."
  use Agentic.LLM.Provider.CodingAgentBase,
    id: :copilot,
    cli_name: "copilot",
    label: "GitHub Copilot"
end
