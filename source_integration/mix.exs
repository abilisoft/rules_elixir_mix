defmodule SourceIntegrationApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :source_integration_app,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:bandit, "~> 1.0"},
        {:jason, "~> 1.4"},
        {:lazy_html, "~> 0.1", only: :test},
        {:phoenix, "~> 1.8.0"},
        {:phoenix_html, "~> 4.1"},
        {:phoenix_live_view, "~> 1.1"}
      ]
    ]
  end

  def application do
    [
      mod: {SourceIntegrationApp.Application, []},
      extra_applications: [:crypto, :logger, :ssl]
    ]
  end
end
