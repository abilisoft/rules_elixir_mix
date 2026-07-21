defmodule Integration.MixProject do
  use Mix.Project

  def project do
    [
      app: :integration,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        ignore_modules: [
          Integration,
          Integration.Application,
          Integration.GeneratedByBazel,
          Integration.Repo,
          IntegrationWeb
        ]
      ],
      deps: [
        {:bandit, "~> 1.0"},
        {:credo, "~> 1.7", runtime: false},
        {:dialyxir, "~> 1.4", runtime: false},
        {:ecto_sql, "~> 3.13"},
        {:jason, "~> 1.4"},
        {:phoenix, "~> 1.8.0"},
        {:phoenix_html, "~> 4.1"},
        {:phoenix_live_view, "~> 1.1"},
        {:postgrex, "~> 0.21"},
        {:sobelow, "~> 0.14", runtime: false},
        {:wallaby, "~> 0.30", only: :test, runtime: false}
      ]
    ]
  end

  def application do
    [
      mod: {Integration.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
