import Config

config :agent_ex,
  telemetry_prefix: [:agent_ex]

import_config "#{config_env()}.exs"
