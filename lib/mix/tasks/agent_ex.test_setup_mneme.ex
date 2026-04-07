defmodule Mix.Tasks.AgentEx.TestSetupMneme do
  @moduledoc """
  Sets up the Mneme test database for integration tests.

  Creates the `mneme_test` database and runs Mneme's migrations.
  Requires PostgreSQL running locally with the `postgres` user.

  ## Usage

      mix agent_ex.test_setup_mneme

  After setup, run integration tests with:

      mix test --include integration
  """

  use Mix.Task

  @shortdoc "Set up Mneme test database for integration tests"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start", [])

    repo = Mneme.TestRepo

    config = Application.get_env(:mneme, repo)

    unless config do
      config =
        [
          database: "mneme_test",
          username: "postgres",
          password: "postgres",
          hostname: "localhost",
          pool_size: 10,
          types: Mneme.PostgrexTypes
        ]

      Application.put_env(:mneme, repo, config)
    end

    Application.put_env(:mneme, :repo, repo)
    Application.put_env(:mneme, :embedding, provider: Mneme.Embedding.Mock, mock: true)

    {:ok, _pid} = repo.start_link()

    migrations =
      case Application.app_dir(:mneme, "priv/repo/migrations") do
        {:error, _} ->
          Path.join([File.cwd!(), "..", "mneme", "priv", "repo", "migrations"])

        path ->
          path
      end

    unless File.dir?(migrations) do
      Mix.raise("Cannot find Mneme migrations at #{migrations}")
    end

    Mix.shell().info("Running Mneme migrations from #{migrations}...")
    :ok = Ecto.Migrator.run(repo, migrations, :up, all: true)
    Mix.shell().info("Mneme test database ready.")

    repo.stop()
  end
end
