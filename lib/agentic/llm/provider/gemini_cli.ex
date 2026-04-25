defmodule Agentic.LLM.Provider.GeminiCli do
  @moduledoc """
  Catalog-only Provider wrapper for Google's Gemini CLI. Unlike
  Cursor / Goose / etc. (which can route to multiple families),
  Gemini CLI exclusively serves Google's Gemini models, so we
  override the default seed set.
  """

  use Agentic.LLM.Provider.CodingAgentBase,
    id: :gemini,
    cli_name: "gemini",
    label: "Gemini CLI",
    model_overrides: [
      {"google/gemini-3-pro", "Gemini 3 Pro", :primary, 1_000_000},
      {"google/gemini-3-flash", "Gemini 3 Flash", :lightweight, 1_000_000}
    ]
end
