defmodule AgentEx.LLM.Provider.Groq do
  @moduledoc """
  Groq provider — the Phase 2 forcing function.

  Uses `AgentEx.LLM.Transport.OpenAIChatCompletions` transport with
  Groq-specific base URL. Zero edits to dispatch/routing code.
  """

  @behaviour AgentEx.LLM.Provider

  alias AgentEx.LLM.{Credentials, Model}

  @impl true
  def id, do: :groq

  @impl true
  def label, do: "Groq"

  @impl true
  def transport, do: AgentEx.LLM.Transport.OpenAIChatCompletions

  @impl true
  def default_base_url, do: "https://api.groq.com/openai/v1"

  @impl true
  def env_vars, do: ["GROQ_API_KEY"]

  @impl true
  def supports, do: MapSet.new([:chat, :tools])

  @impl true
  def request_headers(%Credentials{} = _creds), do: []

  @impl true
  def default_models do
    [
      %Model{
        id: "llama-3.3-70b-versatile",
        provider: :groq,
        label: "Llama 3.3 70B Versatile",
        context_window: 128_000,
        max_output_tokens: 32_768,
        cost: %{input: 0.59, output: 0.79},
        capabilities: MapSet.new([:chat, :tools]),
        tier_hint: :primary,
        source: :static
      },
      %Model{
        id: "llama-3.1-8b-instant",
        provider: :groq,
        label: "Llama 3.1 8B Instant",
        context_window: 128_000,
        max_output_tokens: 8_192,
        cost: %{input: 0.05, output: 0.08},
        capabilities: MapSet.new([:chat, :tools]),
        tier_hint: :lightweight,
        source: :static
      }
    ]
  end

  @impl true
  def fetch_catalog(%Credentials{api_key: api_key} = _creds)
      when is_binary(api_key) and api_key != "" do
    url = "#{default_base_url()}/models"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        parsed =
          models
          |> Enum.map(&parse_model/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def fetch_catalog(_), do: :not_supported

  @impl true
  def fetch_usage(_creds), do: :not_supported

  @impl true
  def classify_http_error(_status, body, _headers) do
    message = stringify_body(body)

    cond do
      String.contains?(message, "model_is_deactivated") ->
        {:model_not_found, nil}

      true ->
        :default
    end
  end

  defp parse_model(raw) do
    id = raw["id"]

    capabilities = MapSet.new([:chat])

    capabilities =
      if raw["tool_use"] != false,
        do: MapSet.put(capabilities, :tools),
        else: capabilities

    context = raw["context_length"] || 8_000

    tier_hint =
      cond do
        context >= 64_000 -> :primary
        context >= 8_000 -> :lightweight
        true -> nil
      end

    %Model{
      id: id,
      provider: :groq,
      label: raw["name"] || id,
      context_window: context,
      max_output_tokens: raw["max_completion_tokens"],
      cost: nil,
      capabilities: capabilities,
      tier_hint: tier_hint,
      source: :discovered
    }
  end

  defp stringify_body(%{"error" => %{"message" => msg}}) when is_binary(msg),
    do: String.downcase(msg)

  defp stringify_body(body) when is_binary(body), do: String.downcase(body)
  defp stringify_body(other), do: String.downcase(inspect(other, limit: 200))
end
