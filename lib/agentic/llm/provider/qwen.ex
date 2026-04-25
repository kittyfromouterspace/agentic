defmodule Agentic.LLM.Provider.Qwen do
  @moduledoc "Catalog-only Provider wrapper for Qwen Code CLI."

  use Agentic.LLM.Provider.CodingAgentBase,
    id: :qwen,
    cli_name: "qwen",
    label: "Qwen Code",
    model_overrides: [
      {"alibaba/qwen3-coder", "Qwen3 Coder", :primary, 256_000},
      {"alibaba/qwen3-max", "Qwen3 Max", :primary, 256_000}
    ]
end
