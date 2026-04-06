defmodule AgentEx.Tools.Activation do
  @moduledoc """
  Tracks which external tools are "activated" (promoted to first-class
  tool schemas) in the current agent session.

  Activated tools appear as top-level tool definitions in the LLM request,
  giving the model direct access without going through `use_tool`.

  A budget system limits how many tools can be active at once to prevent
  context window bloat. When the budget is exceeded, the least-recently-used
  tool is deactivated automatically.

  State is stored in the loop context -- not a separate process --
  because activation is per-session.

  ## Callbacks

  Uses `ctx.callbacks[:get_tool_schema]` to fetch tool schemas on activation.
  """

  @default_budget 10

  @doc "Initialize activation state in ctx."
  def init(ctx, opts \\ []) do
    budget = Keyword.get(opts, :tool_budget, @default_budget)

    Map.put(ctx, :activation, %{
      active: %{},
      budget: budget
    })
  end

  @doc """
  Activate a tool -- add its full schema to the session tool list.

  Returns `{:ok, schema, updated_ctx}` or `{:error, reason}`.
  If budget is exceeded, the LRU tool is auto-deactivated.
  """
  def activate(ctx, tool_name) do
    activation = ctx.activation

    if Map.has_key?(activation.active, tool_name) do
      activation =
        put_in(activation, [:active, tool_name, :last_used], System.monotonic_time())

      {:ok, activation.active[tool_name].schema, %{ctx | activation: activation}}
    else
      get_schema =
        ctx.callbacks[:get_tool_schema] || fn _ -> {:error, :no_tool_schema_provider} end

      case get_schema.(tool_name) do
        {:ok, schema_info} ->
          tool_def = %{
            "name" => schema_info["name"],
            "description" => schema_info["description"],
            "input_schema" => schema_info["input_schema"]
          }

          entry = %{
            schema: tool_def,
            activated_at: System.monotonic_time(),
            last_used: System.monotonic_time(),
            source: schema_info["source"]
          }

          activation = put_in(activation, [:active, tool_name], entry)
          activation = enforce_budget(activation)

          {:ok, tool_def, %{ctx | activation: activation}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Deactivate a tool -- remove it from the session tool list."
  def deactivate(ctx, tool_name) do
    activation = ctx.activation
    activation = %{activation | active: Map.delete(activation.active, tool_name)}
    %{ctx | activation: activation}
  end

  @doc "Touch a tool's last_used timestamp (called on each use)."
  def touch(ctx, tool_name) do
    activation = ctx.activation

    if Map.has_key?(activation.active, tool_name) do
      activation =
        put_in(activation, [:active, tool_name, :last_used], System.monotonic_time())

      %{ctx | activation: activation}
    else
      ctx
    end
  end

  @doc "Get the list of activated tool definitions (for LLM request)."
  def active_tool_definitions(ctx) do
    ctx.activation.active
    |> Map.values()
    |> Enum.map(& &1.schema)
  end

  @doc "List active tool names."
  def active_tool_names(ctx) do
    Map.keys(ctx.activation.active)
  end

  @doc "Check if a tool is activated."
  def active?(ctx, tool_name) do
    Map.has_key?(ctx.activation.active, tool_name)
  end

  @doc "Current activation count vs budget."
  def budget_status(ctx) do
    activation = ctx.activation
    %{active: map_size(activation.active), budget: activation.budget}
  end

  defp enforce_budget(activation) do
    if map_size(activation.active) > activation.budget do
      {lru_name, _entry} =
        Enum.min_by(activation.active, fn {_name, entry} -> entry.last_used end)

      enforce_budget(%{activation | active: Map.delete(activation.active, lru_name)})
    else
      activation
    end
  end
end
