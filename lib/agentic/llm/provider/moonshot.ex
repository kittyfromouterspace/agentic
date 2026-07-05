defmodule Agentic.LLM.Provider.Moonshot do
  @moduledoc """
  Moonshot AI direct API provider — serves the Kimi K2 family.

  OpenAI-compatible (`POST {base_url}/chat/completions`), so this reuses
  the OpenAI Chat Completions transport. This is the **direct API** path
  to Kimi's coding models, as an alternative to the `:kimi` CLI/ACP
  wrapper (`Agentic.LLM.Provider.Kimi`) and the Anthropic-compatible
  coding endpoint (`Agentic.LLM.Provider.KimiCoding`).

  ## Endpoint

    * Global: `https://api.moonshot.ai/v1`
    * China:  `https://api.moonshot.cn/v1` (override via `MOONSHOT_BASE_URL`)

  Auth: `MOONSHOT_API_KEY` (`Authorization: Bearer <KEY>`).

  ## Models

  The coding-optimised models are `kimi-k2.7-code` and
  `kimi-k2.7-code-highspeed`. Thinking is always-on for the `-code`
  variants — the model enables it internally; we do not send a
  `thinking` parameter.

  ## Quirks (from the pi reference implementation)

    * `tool_choice` must be `"auto"` or `"none"` — never `"required"`.
    * `max_tokens` field (not `max_completion_tokens`).
    * No `strict` mode on tool definitions.
    * Temperature is fixed per-model (e.g. 1.0 for k2.7-code); sending
      other values is rejected. Omit temperature unless overridden.

  Model pricing per 1M tokens (USD) — see `default_models/0`.
  """

  @behaviour Agentic.LLM.Provider

  alias Agentic.LLM.{Credentials, Model}

  @impl true
  def id, do: :moonshot

  @impl true
  def label, do: "Moonshot AI"

  @impl true
  def transport, do: Agentic.LLM.Transport.OpenAIChatCompletions

  @impl true
  def default_base_url do
    System.get_env("MOONSHOT_BASE_URL", "https://api.moonshot.ai/v1")
  end

  @impl true
  def env_vars, do: ["MOONSHOT_API_KEY", "MOONSHOT_KEY"]

  @impl true
  def supports, do: MapSet.new([:chat, :tools, :vision, :reasoning])

  @impl true
  def request_headers(%Credentials{} = _creds), do: []

  @impl true
  def default_models do
    [
      %Model{
        id: "kimi-k2.7-code",
        provider: :moonshot,
        label: "Kimi K2.7 Code",
        context_window: 262_144,
        max_output_tokens: 262_144,
        cost: %{input: 0.95, output: 4.0, cache_read: 0.19, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "kimi-k2.7-code-highspeed",
        provider: :moonshot,
        label: "Kimi K2.7 Code HighSpeed",
        context_window: 262_144,
        max_output_tokens: 262_144,
        cost: %{input: 1.9, output: 8.0, cache_read: 0.38, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "kimi-k2.6",
        provider: :moonshot,
        label: "Kimi K2.6",
        context_window: 262_144,
        max_output_tokens: 262_144,
        cost: %{input: 0.95, output: 4.0, cache_read: 0.16, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "kimi-k2.5",
        provider: :moonshot,
        label: "Kimi K2.5",
        context_window: 262_144,
        max_output_tokens: 262_144,
        cost: %{input: 0.60, output: 3.0, cache_read: 0.10, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "kimi-k2-thinking",
        provider: :moonshot,
        label: "Kimi K2 Thinking",
        context_window: 262_144,
        max_output_tokens: 262_144,
        cost: %{input: 0.60, output: 2.5, cache_read: 0.15, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :reasoning]),
        tier_hint: :primary,
        source: :static
      }
    ]
  end

  @impl true
  def fetch_catalog(_creds), do: :not_supported

  # Moonshot exposes no balance/quota endpoint.
  @impl true
  def fetch_usage(_creds), do: :not_supported

  @impl true
  def classify_http_error(_status, _body, _headers), do: :default
end
