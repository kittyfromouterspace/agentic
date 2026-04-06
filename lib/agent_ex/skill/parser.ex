defmodule AgentEx.Skill.Parser do
  @moduledoc """
  Parses SKILL.md files with YAML frontmatter and markdown body.

  The expected format is:

      ---
      name: my-skill
      description: What the skill does and when to use it
      ---

      # Detailed instructions
      ...

  Required frontmatter fields: `name`, `description`.
  Optional: `license`, `metadata` (map), `compatibility`, `type`, `core`,
  `loading`, `version`, `parameters`, `model_tier`.

  ## Skill Types

  - `"skill"` (default) — freeform instructions
  - `"sop"` — structured workflow with steps, constraints, and success criteria

  ## Loading Modes

  - `"on_demand"` (default) — listed by name, loaded via `skill_read` when needed
  - `"always"` — full body included in system prompt
  - `"trigger:<event>"` — loaded when a specific event occurs (e.g. `"trigger:onboarding"`)
  """

  @type parameter :: %{
          name: String.t(),
          required: boolean(),
          default: String.t() | nil,
          description: String.t()
        }

  @type model_tier :: :primary | :lightweight | :any

  @type skill_meta :: %{
          name: String.t(),
          description: String.t(),
          license: String.t() | nil,
          compatibility: String.t() | nil,
          metadata: map(),
          type: String.t(),
          core: boolean(),
          loading: String.t(),
          version: String.t() | nil,
          parameters: [parameter()],
          model_tier: model_tier()
        }

  @type parsed_skill :: %{
          meta: skill_meta(),
          body: String.t(),
          raw: String.t()
        }

  @doc "Parse SKILL.md content string."
  @spec parse(String.t()) :: {:ok, parsed_skill()} | {:error, String.t()}
  def parse(content) when is_binary(content) do
    trimmed = String.trim_leading(content)

    with {:ok, frontmatter_str, body} <- split_frontmatter(trimmed),
         {:ok, yaml} <- parse_yaml(frontmatter_str),
         {:ok, meta} <- extract_meta(yaml) do
      {:ok, %{meta: meta, body: String.trim(body), raw: content}}
    end
  end

  @doc "Read and parse a SKILL.md file from disk."
  @spec parse_file(String.t()) :: {:ok, parsed_skill()} | {:error, String.t()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end

  # --- Private ---

  defp split_frontmatter("---" <> rest) do
    case String.split(rest, ~r/\n---\s*\n/, parts: 2) do
      [frontmatter, body] ->
        {:ok, String.trim(frontmatter), body}

      [frontmatter] ->
        # Handle case where --- is at end of file with no trailing newline
        case String.split(frontmatter, ~r/\n---\s*$/, parts: 2) do
          [fm, trailing] -> {:ok, String.trim(fm), trailing}
          _ -> {:ok, String.trim(frontmatter), ""}
        end
    end
  end

  defp split_frontmatter(_), do: {:error, "SKILL.md must start with --- frontmatter delimiter"}

  defp parse_yaml(yaml_str) do
    case YamlElixir.read_from_string(yaml_str) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "Frontmatter must be a YAML mapping"}
      {:error, %YamlElixir.ParsingError{message: msg}} -> {:error, "Invalid YAML: #{msg}"}
      {:error, reason} -> {:error, "Invalid YAML: #{inspect(reason)}"}
    end
  end

  defp extract_meta(yaml) do
    name = yaml["name"]
    description = yaml["description"]

    cond do
      is_nil(name) or name == "" ->
        {:error, "Missing required field: name"}

      is_nil(description) or description == "" ->
        {:error, "Missing required field: description"}

      true ->
        type = to_string(yaml["type"] || "skill")
        loading = to_string(yaml["loading"] || "on_demand")

        with :ok <- validate_type(type),
             :ok <- validate_loading(loading) do
          {:ok,
           %{
             name: to_string(name),
             description: to_string(description),
             license: yaml["license"] && to_string(yaml["license"]),
             compatibility: yaml["compatibility"] && to_string(yaml["compatibility"]),
             metadata: yaml["metadata"] || %{},
             type: type,
             core: yaml["core"] == true,
             loading: loading,
             version: yaml["version"] && to_string(yaml["version"]),
             parameters: parse_parameters(yaml["parameters"]),
             model_tier: parse_model_tier(yaml["model_tier"]),
             source: yaml["source"] && to_string(yaml["source"])
           }}
        end
    end
  end

  @valid_types ~w(skill sop)
  @valid_loading_prefixes ~w(on_demand always)

  defp validate_type(type) when type in @valid_types, do: :ok
  defp validate_type(type), do: {:error, "Invalid type '#{type}'. Must be 'skill' or 'sop'."}

  defp validate_loading(loading) when loading in @valid_loading_prefixes, do: :ok
  defp validate_loading("trigger:" <> event) when byte_size(event) > 0, do: :ok

  defp validate_loading(loading),
    do:
      {:error,
       "Invalid loading '#{loading}'. Must be 'on_demand', 'always', or 'trigger:<event>'."}

  defp parse_parameters(nil), do: []

  defp parse_parameters(params) when is_list(params) do
    Enum.map(params, fn
      param when is_map(param) ->
        %{
          name: to_string(param["name"] || ""),
          required: param["required"] == true,
          default: param["default"] && to_string(param["default"]),
          description: to_string(param["description"] || "")
        }

      param when is_binary(param) ->
        %{name: param, required: false, default: nil, description: ""}
    end)
  end

  defp parse_parameters(_), do: []

  @valid_model_tiers %{"primary" => :primary, "lightweight" => :lightweight, "any" => :any}

  defp parse_model_tier(nil), do: :any
  defp parse_model_tier(tier) when is_binary(tier), do: Map.get(@valid_model_tiers, tier, :any)
  defp parse_model_tier(_), do: :any
end
