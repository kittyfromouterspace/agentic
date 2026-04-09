defmodule AgentEx.AgentProtocol.CLI do
  @moduledoc """
  Behaviour for CLI-based local agent protocols.

  Extends AgentProtocol with CLI-specific lifecycle, configuration,
  and availability checking.

  ## CLI Configuration

  The configuration maps to OpenClaw's `CliBackendConfig` with these key fields:

  ```elixir
  %{
    command: "claude",           # CLI binary name or path
    args: ["-p", "--output-format", "stream-json"],  # base args
    env: %{...},                 # extra env vars
    clear_env: [...],            # env vars to remove
    session_mode: :always,       # :always | :existing | :none
    session_id_fields: ["session_id"],  # where to find session ID in output
    session_args: [...],         # extra args for resuming
    system_prompt_mode: :append, # :append | :replace
    system_prompt_when: :first,  # :first | :always | :never
    reliability: %{
      watchdog: %{
        fresh: %{no_output_timeout_ms: 120_000},
        resume: %{no_output_timeout_ms: 300_000}
      }
    }
  }
  ```

  ## Usage

  Use this behaviour in your protocol implementation:

  ```elixir
  defmodule MyAgentProtocol do
    use AgentEx.AgentProtocol.CLI

    @impl true
    def cli_name, do: "my-agent"

    @impl true
    def build_config(profile_config) do
      %{
        command: "my-agent",
        args: ["-p", "--output-format", "stream-json"],
        session_mode: :always,
        session_id_fields: ["session_id"]
      }
    end
  end
  ```
  """

  @type cli_config :: %{
          required(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:env) => %{String.t() => String.t()},
          optional(:clear_env) => [String.t()],
          optional(:session_mode) => :always | :existing | :none,
          optional(:session_id_fields) => [String.t()],
          optional(:session_args) => [String.t()],
          optional(:resume_args) => [String.t()],
          optional(:system_prompt_arg) => String.t(),
          optional(:system_prompt_mode) => :append | :replace,
          optional(:system_prompt_when) => :first | :always | :never,
          optional(:model_arg) => String.t(),
          optional(:model_aliases) => %{String.t() => String.t()},
          optional(:image_arg) => String.t(),
          optional(:image_mode) => :repeat | :list,
          optional(:serialize) => boolean(),
          optional(:reliability) => map()
        }

  @doc """
  Build CLI-specific configuration from profile config.

  Merges default CLI config with profile-specific overrides.
  """
  @callback build_config(profile_config :: map()) :: cli_config()

  @doc """
  Return the CLI binary name for this protocol.

  Used for availability checking and logging.
  """
  @callback cli_name() :: String.t()
  def cli_name, do: raise("Not implemented")

  @doc """
  Get CLI version string.

  Useful for debugging and compatibility checking.
  """
  @callback cli_version() :: String.t() | nil

  @doc """
  Default args for fresh session (non-resume).

  Override to customize base CLI arguments.
  """
  @callback default_args() :: [String.t()]

  @doc """
  Args used when resuming an existing session.

  Use `{sessionId}` placeholder for session ID injection.
  """
  @callback resume_args() :: [String.t()]

  @doc """
  Format the session ID argument for CLI.

  Default: `--session-id {sessionId}`
  """
  @callback format_session_arg(session_id :: String.t(), cli_config :: cli_config()) ::
              [String.t()]

  @doc """
  Extract session ID from CLI output.

  Searches the response metadata for session ID using configured field names.
  """
  @callback extract_session_id(response :: map(), cli_config :: cli_config()) ::
              String.t() | nil

  @doc """
  Format system prompt for CLI.

  Handles the different modes (append vs replace, first vs always).
  """
  @callback format_system_prompt(
              system_prompt :: String.t(),
              is_first :: boolean(),
              cli_config :: cli_config()
            ) :: [String.t()] | nil

  @doc """
  Merge environment variables for CLI execution.

  Combines host-managed env vars with protocol-specific vars.
  """
  @callback merge_env(cli_config :: cli_config(), extra_env :: map()) :: [
              {String.t(), String.t()}
            ]

  # --- Default implementations inheriting from AgentProtocol ---

  defmacro __using__(opts) do
    quote do
      use AgentEx.AgentProtocol, unquote(opts)

      @behaviour unquote(__MODULE__)
    end
  end
end
