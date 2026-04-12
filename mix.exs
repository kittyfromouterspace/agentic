defmodule AgentEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_ex,
      version: "0.1.2",
      elixir: "~> 1.19",
      description: "A composable AI agent runtime",
      package: [
        licenses: ["BSD-3-Clause"],
        links: %{"GitHub" => "https://github.com/kittyfromouterspace/agent_ex"}
      ],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AgentEx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.9"},
      {:req, "~> 0.5"},
      {:nimble_options, "~> 1.1"},
      # Mneme memory engine - now supports both PostgreSQL and libSQL
      # {:mneme, path: "../mneme"},
      {:mneme, git: "https://github.com/kittyfromouterspace/mneme.git", tag: "v0.2.1"},
      {:ecto_sql, "~> 3.12"},
      # Database drivers (optional - pick one based on your backend)
      {:postgrex, "~> 0.19", optional: true},
      {:ecto_libsql, "~> 0.9", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ex_check, "~> 0.16", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
