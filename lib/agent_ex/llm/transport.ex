defmodule AgentEx.LLM.Transport do
  @moduledoc """
  Behaviour describing one wire-protocol family used to talk to LLM
  providers. A transport is **pure**: it knows how to translate a
  canonical request shape into an HTTP request and how to parse the
  HTTP response back into the shared `AgentEx.LLM.Response` /
  `AgentEx.LLM.Error` structs. It does not perform any network I/O,
  does not look up credentials, and does not implement any
  provider-specific business logic.

  ## Canonical chat params

  Every transport accepts the same canonical chat params map. The
  per-provider shim is responsible for translating its own input shape
  into this canonical form before calling
  `c:build_chat_request/2`.

      %{
        model: String.t(),
        messages: [%{role: String.t() | atom(), content: term()}],
        system: nil | String.t() | [map()],
        tools: [%{name: ..., description: ..., input_schema: ...}],
        max_tokens: pos_integer() | nil,
        temperature: float() | nil,
        tool_choice: nil | :auto | :none | :any | %{name: String.t()},
        cache_control: nil | %{
          stable_hash: String.t(),
          prefix_changed: boolean()
        }
      }

  Transports MUST tolerate missing optional keys (`tools`, `system`,
  `tool_choice`, `temperature`, `cache_control`) by treating them
  as absent. Transports that don't implement provider-side prompt
  caching ignore `cache_control` entirely; transports that do (e.g.
  `AgentEx.LLM.Transport.AnthropicMessages`) read `prefix_changed`
  to decide whether to mark cache breakpoints in the request body.

  ## Opts

  `c:build_chat_request/2` receives an `opts` keyword list whose keys
  are intentionally narrow:

    * `:base_url`      — required, fully-qualified provider base URL
                          (no trailing slash needed)
    * `:api_key`       — required, raw bearer / api key value
    * `:extra_headers` — optional, list of extra `{name, value}` tuples
                          for provider-specific headers (e.g.
                          `HTTP-Referer`, `anthropic-version`)

  Phase 2 will move credential lookup behind a Provider behaviour and
  the shim/`opts[:api_key]` plumbing will go away. For Phase 1 the
  shim still hands the api key in directly.
  """

  alias AgentEx.LLM.{Error, RateLimit, Response}

  @type canonical_params :: %{
          required(:model) => String.t(),
          required(:messages) => list(),
          optional(:system) => String.t() | list() | nil,
          optional(:tools) => list(),
          optional(:max_tokens) => pos_integer() | nil,
          optional(:temperature) => float() | nil,
          optional(:tool_choice) => term(),
          optional(:cache_control) => map() | nil
        }

  @type request :: %{
          method: :post,
          url: String.t(),
          body: map(),
          headers: [{String.t(), String.t()}]
        }

  @callback id() :: atom()

  @callback build_chat_request(canonical_params(), keyword()) :: request()

  @callback parse_chat_response(non_neg_integer(), term(), term()) ::
              {:ok, Response.t()} | {:error, Error.t()}

  @callback parse_rate_limit(term()) :: RateLimit.t() | nil

  @doc """
  Optional embedding callbacks. A transport that does not implement
  these will not be usable for embedding requests.

  ## Opts (build_embedding_request/2)

    * `:base_url`      — required, fully-qualified provider base URL
    * `:api_key`       — required, raw bearer / api key value
    * `:model`         — required, embedding model id
    * `:extra_headers` — optional, list of extra `{name, value}` tuples

  ## Response shape

  `parse_embedding_response/3` always returns a list of vectors,
  even when the original input was a single string. The caller is
  responsible for indexing into the list when it knows it submitted
  a single text.
  """
  @callback build_embedding_request(text_or_list :: String.t() | [String.t()], opts :: keyword()) ::
              request() | :not_supported

  @callback parse_embedding_response(
              status :: non_neg_integer(),
              body :: term(),
              headers :: term()
            ) :: {:ok, [[float()]]} | {:error, Error.t()} | :not_supported

  @optional_callbacks build_embedding_request: 2, parse_embedding_response: 3
end
