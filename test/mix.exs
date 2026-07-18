defmodule AnalysisFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :analysis_fixture,
      test_coverage: [ignore_modules: [AnalysisProtocol.Atom]],
      version: "0.1.0"
    ]
  end
end
