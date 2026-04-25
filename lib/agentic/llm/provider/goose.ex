defmodule Agentic.LLM.Provider.Goose do
  @moduledoc "Catalog-only Provider wrapper for the Goose agent CLI."
  use Agentic.LLM.Provider.CodingAgentBase,
    id: :goose,
    cli_name: "goose",
    label: "Goose"
end
