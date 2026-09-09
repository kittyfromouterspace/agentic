defmodule Agentic.MixProject do
  use Mix.Project

  def project do
    [
      app: :agentic,
      version: "0.3.1",
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
      {:recollect, "~> 0.5"},
      # decimal 3 forced past ex_money 5.x, which caps it at `~> 1.6 or ~> 2.0`.
      # Closes EEF-CVE-2026-32686 (unbounded exponent -> unauthenticated DoS) and
      # unblocks ecto 3.14, which requires decimal ~> 3.0. The alternative was
      # ex_money 6, which drops ex_cldr for `localize` and breaks Agentic.Cldr —
      # a localization migration, not a security fix. Operator-approved
      # 2026-09-07: the decimal 2 -> 3 delta is small (B-1413).
      {:decimal, "~> 3.1", override: true},
      {:ex_money, "~> 5.24"},
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
