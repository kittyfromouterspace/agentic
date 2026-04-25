defmodule Agentic.LLM.Provider.CodingAgentBase do
  @moduledoc """
  Macro that synthesizes a catalog-only `Agentic.LLM.Provider`
  implementation for an ACP-compatible coding-agent CLI (Cursor,
  Gemini CLI, Goose, GitHub Copilot, Kimi, Qwen, …).

  These agents all route to one or more of the big frontier model
  families internally — most expose Anthropic Claude, OpenAI GPT,
  and Google Gemini. We surface them in the Catalog as alternative
  pathways for those same canonical model families so the
  multi-pathway router can score them alongside Anthropic-direct,
  OpenRouter, etc.

  ## Usage

      defmodule Agentic.LLM.Provider.Cursor do
        use Agentic.LLM.Provider.CodingAgentBase,
          id: :cursor,
          cli_name: "cursor-agent",
          label: "Cursor",
          # Optional — defaults to the frontier coding set below.
          # Each tuple is {provider_local_id, label, tier, ctx_window}
          model_overrides: [...]
      end

  ## Why a macro

  Per-agent modules get a single place each (~5 lines) and the
  shared catalog/availability machinery lives here. Adding a new
  detected agent is a trivial PR. The model list defaults are
  intentionally a small "frontier coding" set — agents that route
  exclusively to one family override `model_overrides`.
  """

  @doc """
  Default model seeds used by every ACP coding agent that doesn't
  override them. Mirrors what `Agentic.LLM.Provider.OpenCode`
  declared — the canonical_id mapping in `Canonical` then groups
  these with their HTTP siblings.
  """
  def default_seeds do
    [
      {"anthropic/claude-sonnet-4", "Claude Sonnet 4", :primary, 200_000},
      {"anthropic/claude-opus-4", "Claude Opus 4", :primary, 200_000},
      {"openai/gpt-5.5", "GPT-5.5", :primary, 200_000},
      {"google/gemini-3-pro", "Gemini 3 Pro", :primary, 1_000_000}
    ]
  end

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    cli_name = Keyword.fetch!(opts, :cli_name)
    label = Keyword.fetch!(opts, :label)
    model_overrides = Keyword.get(opts, :model_overrides)

    quote do
      @behaviour Agentic.LLM.Provider

      alias Agentic.LLM.{Credentials, Model}

      @cli_name unquote(cli_name)

      @impl true
      def id, do: unquote(id)

      @impl true
      def label, do: unquote(label) <> " (CLI)"

      @impl true
      def transport, do: Agentic.LLM.Transport.OpenAIChatCompletions

      @impl true
      def default_base_url, do: nil

      @impl true
      def env_vars, do: []

      @impl true
      def supports, do: MapSet.new([:chat, :tools])

      @impl true
      def request_headers(%Credentials{} = _creds), do: []

      @impl true
      def default_models do
        provider_id = unquote(id)

        seeds = unquote(model_overrides) || Agentic.LLM.Provider.CodingAgentBase.default_seeds()

        agent_label = unquote(label)

        Enum.map(seeds, fn {model_id, model_label, tier, ctx} ->
          %Model{
            id: model_id,
            provider: provider_id,
            label: "#{model_label} (via #{agent_label})",
            context_window: ctx,
            max_output_tokens: 8_192,
            cost: %{input: 0.0, output: 0.0},
            capabilities: MapSet.new([:chat, :tools]),
            tier_hint: tier,
            source: :static
          }
        end)
      end

      @impl true
      def fetch_catalog(_creds), do: :not_supported

      @impl true
      def fetch_usage(_creds), do: :not_supported

      @impl true
      def classify_http_error(_status, _body, _headers), do: :default

      @doc "Three-state availability for the #{unquote(label)} CLI pathway."
      @spec availability(any()) :: :ready | :unavailable
      def availability(_account \\ nil) do
        if System.find_executable(@cli_name), do: :ready, else: :unavailable
      end
    end
  end
end
