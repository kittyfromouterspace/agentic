defmodule Agentic.LLM.Provider.Zai do
  @moduledoc """
  z.ai (formerly Zhipu) Provider — OpenAI-compatible.

  z.ai serves the GLM family. The wire format is OpenAI-compatible
  (`Authorization: Bearer <KEY>`), so this provider reuses the OpenAI
  Chat Completions transport with a different base URL.

  ## Endpoints

    * Global (USD billing): `https://api.z.ai/api/paas/v4/`
    * China (CNY billing): `https://open.bigmodel.cn/api/paas/v4/`
    * Coding-Plan keys: `https://api.z.ai/api/coding/paas/v4/`
      (China coding: `https://open.bigmodel.cn/api/coding/paas/v4/`)

  We default to the global pay-as-you-go endpoint. **Coding-plan
  subscribers** must point at the coding endpoint by setting
  `ZAI_BASE_URL=https://api.z.ai/api/coding/paas/v4`. On the coding plan
  the GLM-5 family (glm-5.2, glm-5.1, glm-5-turbo, glm-5v-turbo) is
  served under a flat subscription, so per-token costs there are zero.

  z.ai exposes **no `/models` endpoint** and **no balance/quota endpoint**;
  the model list is static and per-account quotas are dashboard-only at
  https://z.ai/manage-apikey/billing.

  Model pricing per 1M tokens (USD):

      glm-4.5         $0.60 / $2.20    131k ctx
      glm-4.5-air     $0.13 / $0.85    131k
      glm-4.5-flash   $0.00 / $0.00     128k  (free tier; rate-limited)
      glm-4.6         $0.39 / $1.74    205k
      glm-4.7         $0.38 / $1.74    203k
      glm-4.7-flash   $0.06 / $0.40    203k
  """

  @behaviour Agentic.LLM.Provider

  alias Agentic.LLM.{Credentials, Model}

  @impl true
  def id, do: :zai

  @impl true
  def label, do: "z.ai"

  @impl true
  def transport, do: Agentic.LLM.Transport.OpenAIChatCompletions

  @impl true
  def default_base_url do
    System.get_env("ZAI_BASE_URL", "https://api.z.ai/api/paas/v4")
  end

  @impl true
  def env_vars, do: ["ZAI_API_KEY", "Z_AI_API_KEY"]

  @impl true
  def supports, do: MapSet.new([:chat, :tools])

  @impl true
  def request_headers(%Credentials{} = _creds), do: []

  @impl true
  def default_models do
    [
      %Model{
        id: "glm-4.7",
        provider: :zai,
        label: "GLM-4.7",
        context_window: 203_000,
        max_output_tokens: 8_192,
        cost: %{input: 0.38, output: 1.74},
        capabilities: MapSet.new([:chat, :tools]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "glm-4.7-flash",
        provider: :zai,
        label: "GLM-4.7 Flash",
        context_window: 203_000,
        max_output_tokens: 8_192,
        cost: %{input: 0.06, output: 0.40},
        capabilities: MapSet.new([:chat, :tools]),
        tier_hint: :lightweight,
        source: :static
      },
      %Model{
        id: "glm-4.6",
        provider: :zai,
        label: "GLM-4.6",
        context_window: 205_000,
        max_output_tokens: 8_192,
        cost: %{input: 0.39, output: 1.74},
        capabilities: MapSet.new([:chat, :tools]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "glm-4.5",
        provider: :zai,
        label: "GLM-4.5",
        context_window: 131_000,
        max_output_tokens: 8_192,
        cost: %{input: 0.60, output: 2.20},
        capabilities: MapSet.new([:chat, :tools]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "glm-4.5-air",
        provider: :zai,
        label: "GLM-4.5 Air",
        context_window: 131_000,
        max_output_tokens: 8_192,
        cost: %{input: 0.13, output: 0.85},
        capabilities: MapSet.new([:chat, :tools]),
        tier_hint: :lightweight,
        source: :static
      },
      %Model{
        id: "glm-5.2",
        provider: :zai,
        label: "GLM-5.2",
        context_window: 1_000_000,
        max_output_tokens: 131_072,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:chat, :tools, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "glm-5.1",
        provider: :zai,
        label: "GLM-5.1",
        context_window: 200_000,
        max_output_tokens: 131_072,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:chat, :tools, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "glm-5-turbo",
        provider: :zai,
        label: "GLM-5 Turbo",
        context_window: 200_000,
        max_output_tokens: 131_072,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:chat, :tools, :reasoning]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "glm-5v-turbo",
        provider: :zai,
        label: "GLM-5V Turbo",
        context_window: 200_000,
        max_output_tokens: 131_072,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:chat, :tools, :vision, :reasoning]),
        tier_hint: :primary,
        source: :static
      }
    ]
  end

  @impl true
  def fetch_catalog(_creds), do: :not_supported

  # No usage/balance endpoint — link out to dashboard.
  @impl true
  def fetch_usage(_creds), do: :not_supported

  @impl true
  def classify_http_error(_status, _body, _headers), do: :default
end
