defmodule EscriptFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :escript_fixture,
      deps: [],
      elixir: "~> 1.20",
      escript: [main_module: EscriptFixture],
      version: "0.1.0"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
