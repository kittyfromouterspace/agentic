import Config

config :agent_ex,
  telemetry_prefix: [:agent_ex],
  providers: [
    AgentEx.LLM.Provider.Anthropic,
    AgentEx.LLM.Provider.OpenAI,
    AgentEx.LLM.Provider.OpenRouter,
    AgentEx.LLM.Provider.Groq,
    AgentEx.LLM.Provider.Ollama
  ],
  catalog: [
    persist_path: "~/.worth/catalog.json",
    refresh_interval_ms: 600_000
  ]

import_config "#{config_env()}.exs"
