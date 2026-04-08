defmodule AgentEx.LLM.Provider.Ollama do
  @moduledoc """
  Ollama provider — local-first chat and embeddings.

  Uses `AgentEx.LLM.Transport.Ollama`. The base URL defaults to
  `http://localhost:11434` and may be overridden by `OLLAMA_HOST`.
  No API key is required; `Credentials.resolve/1` returns a credential
  with `api_key: nil` for `:ollama`.
  """

  @behaviour AgentEx.LLM.Provider

  alias AgentEx.LLM.{Credentials, Model}

  require Logger

  @default_base_url "http://localhost:11434"

  @impl true
  def id, do: :ollama

  @impl true
  def label, do: "Ollama"

  @impl true
  def transport, do: AgentEx.LLM.Transport.Ollama

  @impl true
  def default_base_url, do: System.get_env("OLLAMA_HOST") || @default_base_url

  @impl true
  def env_vars, do: ["OLLAMA_HOST"]

  @impl true
  def supports, do: MapSet.new([:chat, :embeddings, :tools])

  @impl true
  def request_headers(%Credentials{} = _creds), do: []

  @impl true
  def default_models do
    [
      %Model{
        id: "llama3.2",
        provider: :ollama,
        label: "Llama 3.2",
        context_window: 128_000,
        max_output_tokens: 4096,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:chat, :tools, :free]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "nomic-embed-text",
        provider: :ollama,
        label: "Nomic Embed Text",
        context_window: 8192,
        max_output_tokens: nil,
        cost: %{input: 0.0, output: 0.0},
        capabilities: MapSet.new([:embeddings, :free]),
        tier_hint: nil,
        source: :static
      }
    ]
  end

  @impl true
  def fetch_catalog(_creds) do
    url = "#{default_base_url()}/api/tags"

    case Req.get(url, receive_timeout: 3_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        parsed =
          models
          |> Enum.map(&parse_model/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, _reason} ->
        :not_supported
    end
  rescue
    _ -> :not_supported
  end

  @impl true
  def fetch_usage(_creds), do: :not_supported

  @impl true
  def classify_http_error(_status, _body, _headers), do: :default

  defp parse_model(%{"name" => name} = raw) do
    is_embedding = embedding_model?(name)

    capabilities =
      if is_embedding do
        MapSet.new([:embeddings, :free])
      else
        MapSet.new([:chat, :tools, :free])
      end

    %Model{
      id: name,
      provider: :ollama,
      label: raw["name"],
      context_window: get_in(raw, ["details", "context_length"]) || 8192,
      max_output_tokens: nil,
      cost: %{input: 0.0, output: 0.0},
      capabilities: capabilities,
      tier_hint: if(is_embedding, do: nil, else: :primary),
      source: :discovered
    }
  end

  defp parse_model(_), do: nil

  defp embedding_model?(name) when is_binary(name) do
    lower = String.downcase(name)

    Enum.any?(
      ["embed", "bge-", "nomic-embed", "mxbai-embed", "all-minilm", "snowflake-arctic-embed"],
      &String.contains?(lower, &1)
    )
  end

  defp embedding_model?(_), do: false
end
