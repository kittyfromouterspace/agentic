defmodule AgentEx.LLM.Credentials do
  @moduledoc """
  Resolved credentials for a single provider.

  `resolve/1` walks the provider's declared `env_vars/0` in priority
  order and returns the first non-empty value wrapped in a `%Credentials{}`
  struct. The provider knows its own env var names; nothing else does.

  `resolve/2` accepts an opts keyword list. If `opts[:api_key]` is set,
  it is used directly instead of looking up env vars. This allows the
  host application to inject keys per-call (e.g. from an encrypted store).

  Runtime credentials can also be stored via `put/2` and are checked
  before environment variables.
  """

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          headers: [{String.t(), String.t()}],
          base_url_override: String.t() | nil,
          source: {:env, String.t()} | :injected | :none
        }

  defstruct api_key: nil,
            headers: [],
            base_url_override: nil,
            source: :none

  @table :agent_ex_credentials

  @doc """
  Initialize the ETS credential store. Call once at app startup.
  """
  @spec init_store() :: :ok
  def init_store do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Store a credential in the runtime ETS store.
  """
  @spec put(String.t(), String.t()) :: true
  def put(env_var, key) when is_binary(env_var) and is_binary(key) do
    :ets.insert(@table, {env_var, key})
  end

  @doc """
  Resolve credentials for a provider module.

  When `opts[:api_key]` is provided, uses that directly instead of
  looking up environment variables. Falls back to env var lookup.

      iex> Credentials.resolve(AgentEx.LLM.Provider.OpenAI)
      {:ok, %Credentials{api_key: "sk-...", source: {:env, "OPENAI_API_KEY"}}}

      iex> Credentials.resolve(AgentEx.LLM.Provider.OpenAI, api_key: "sk-direct")
      {:ok, %Credentials{api_key: "sk-direct", source: :injected}}
  """
  @spec resolve(module(), keyword()) :: {:ok, t()} | :not_configured
  def resolve(provider, opts \\ []) when is_atom(provider) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" ->
        {:ok,
         %__MODULE__{
           api_key: key,
           headers: provider.request_headers(%__MODULE__{api_key: key}),
           source: :injected
         }}

      _ ->
        resolve_from_env(provider)
    end
  end

  @doc "Returns `true` when the provider has a usable credential."
  @spec available?(module()) :: boolean()
  def available?(provider) when is_atom(provider) do
    case resolve(provider) do
      {:ok, %__MODULE__{api_key: nil}} -> provider.id() == :ollama
      {:ok, %__MODULE__{}} -> true
      :not_configured -> false
    end
  end

  defp resolve_from_env(provider) do
    env_vars = provider.env_vars()

    case find_first_env(env_vars) do
      {:ok, {var, key}} ->
        {:ok,
         %__MODULE__{
           api_key: key,
           headers: provider.request_headers(%__MODULE__{api_key: key}),
           source: {:env, var}
         }}

      :none ->
        if provider.id() == :ollama do
          {:ok,
           %__MODULE__{
             api_key: nil,
             headers: provider.request_headers(%__MODULE__{}),
             source: :none
           }}
        else
          :not_configured
        end
    end
  end

  defp find_first_env([]), do: :none

  defp find_first_env([var | rest]) when is_binary(var) do
    case lookup_store(var) || System.get_env(var) do
      nil -> find_first_env(rest)
      "" -> find_first_env(rest)
      key -> {:ok, {var, key}}
    end
  end

  defp lookup_store(var) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ref ->
        case :ets.lookup(@table, var) do
          [{^var, key}] -> key
          _ -> nil
        end
    end
  end
end
