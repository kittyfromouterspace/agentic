defmodule Agentic.LLM.Provider.Cursor do
  @moduledoc "Catalog-only Provider wrapper for the Cursor agent CLI."
  use Agentic.LLM.Provider.CodingAgentBase,
    id: :cursor,
    cli_name: "cursor-agent",
    label: "Cursor"
end
