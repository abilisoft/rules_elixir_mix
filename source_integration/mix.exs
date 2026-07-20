defmodule SourceIntegrationApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :source_integration_app,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: true,
      deps: []
    ]
  end

  def application do
    [
      mod: {SourceIntegrationApp.Application, []},
      extra_applications: [:crypto, :logger, :ssl]
    ]
  end
end
