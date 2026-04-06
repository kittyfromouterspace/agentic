defmodule AgentEx.Loop.Stage do
  @moduledoc """
  Behaviour for loop pipeline stages.

  Each stage receives a context and a `next` function representing the rest of
  the pipeline. Stages can:

  - **Pass through**: call `next.(context)` to continue the pipeline
  - **Short-circuit**: return `{:done, result}` to stop the pipeline
  - **Transform**: modify context before calling `next`
  - **Loop**: call `next` multiple times (e.g. StopReasonRouter)

  Stages optionally declare a `model_tier/0` if they need an LLM model.
  """

  @type context :: map()
  @type result :: {:ok, context()} | {:done, map()} | {:error, term()}
  @type next :: (context() -> result())

  @doc "Execute this stage. Call `next.(context)` to continue the pipeline."
  @callback call(context(), next()) :: result()

  @doc """
  The model tier this stage needs (e.g. :primary, :lightweight, :image, :vision).
  Return `nil` if no model is needed.
  """
  @callback model_tier() :: atom() | nil

  @optional_callbacks [model_tier: 0]
end
