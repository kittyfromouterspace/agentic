defmodule Agentic.MixProject do
  use Mix.Project

  def project do
    [
      app: :agentic,
      version: "0.4.0",
      elixir: "~> 1.19",
      description: "A composable AI agent runtime",
      package: [
        files:
          ~w(lib priv config README.md LICENSE mix.exs .formatter.exs usage-rules.md usage-rules),
        licenses: ["BSD-3-Clause"],
        links: %{"GitHub" => "https://github.com/kittyfromouterspace/agentic"}
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
      mod: {Agentic.Application, []}
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
      {:recollect, "~> 1.0"},
      # ex_money 6 drops ex_cldr (uses ex_cldr_numbers) and natively requires
      # decimal ~> 3.0, so the override can come off.
      {:ex_money, "~> 6.0"},
      # ex_money 6 dropped ex_cldr; Agentic.Cldr does `use Cldr` directly, so
      # declare ex_cldr directly (it natively requires decimal ~> 3.0).
      {:ex_cldr, "~> 2.47"},
      {:exqlite, "~> 0.27"},
      {:ecto_sql, "~> 3.12", optional: true},
      {:postgrex, "~> 0.19", optional: true},
      {:ecto_libsql, "~> 0.9", optional: true},
      {:ecto_sqlite3, "~> 0.18", optional: true},
      {:sqlite_vec, "~> 0.1", optional: true},
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
