defmodule Agentic.LLM.Provider.KimiCoding do
  @moduledoc """
  Kimi For Coding — Moonshot's Anthropic-compatible coding API.

  This is the **coding-plan** path to Kimi, distinct from the
  OpenAI-compatible direct API (`Agentic.LLM.Provider.Moonshot`) and the
  CLI/ACP wrapper (`Agentic.LLM.Provider.Kimi`). The endpoint speaks the
  Anthropic Messages wire format, so this reuses the Anthropic Messages
  transport with a different base URL and a mandatory `User-Agent`
  header.

  ## Endpoint

      Base:  https://api.kimi.com/coding/v1
      POST:  .../messages        (assembled by the Anthropic transport)

  Auth: `KIMI_API_KEY` (sent as `x-api-key` by the Anthropic transport).

  ## Mandatory header

  Moonshot's coding gateway checks the client identity, so every request
  carries `User-Agent: KimiCLI/1.5` (set in `request_headers/1`). Without
  it the gateway rejects requests as not coming from the official client.

  ## Models

  All models are reachable on the coding plan (flat subscription), so
  per-token costs are zero here. `kimi-for-coding` is the canonical
  alias; `k2p7` is the dated alias for Kimi K2.7 Code.

  ## Quirks

    * Reasoning/thinking is always-on; do not try to disable it.
    * Anthropic Messages format: system prompt, tool definitions, and
      tool results all follow the Anthropic shape (handled by the
      transport).
  """

  @behaviour Agentic.LLM.Provider

  alias Agentic.LLM.{Credentials, Model}

  @kimi_user_agent "KimiCLI/1.5"

  @impl true
  def id, do: :kimi_coding

  @impl true
  def label, do: "Kimi For Coding"

  @impl true
  def transport, do: Agentic.LLM.Transport.AnthropicMessages

  @impl true
  def default_base_url do
    System.get_env("KIMI_CODING_BASE_URL", "https://api.kimi.com/coding/v1")
  end

  @impl true
  def env_vars, do: ["KIMI_API_KEY"]

  @impl true
  def supports, do: MapSet.new([:chat, :tools, :vision, :reasoning])

  @impl true
  def request_headers(%Credentials{} = _creds) do
    [{"User-Agent", @kimi_user_agent}]
  end

  @impl true
  def default_models do
    [
      %Model{
        id: "kimi-for-coding",
        provider: :kimi_coding,
        label: "Kimi For Coding",
        context_window: 262_144,
        max_output_tokens: 32_768,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "k2p7",
        provider: :kimi_coding,
        label: "Kimi K2.7 Code",
        context_window: 262_144,
        max_output_tokens: 32_768,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "kimi-k2-thinking",
        provider: :kimi_coding,
        label: "Kimi K2 Thinking",
        context_window: 262_144,
        max_output_tokens: 32_768,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        capabilities: MapSet.new([:chat, :tools, :reasoning]),
        tier_hint: :primary,
        source: :static
      }
    ]
  end

  @impl true
  def fetch_catalog(_creds), do: :not_supported

  @impl true
  def fetch_usage(_creds), do: :not_supported

  @impl true
  def classify_http_error(_status, _body, _headers), do: :default
end
