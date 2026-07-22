defmodule SourceIntegrationApp.MixProject do
  use Mix.Project

  def project do
    verify_rustler_precompiled_target!()

    [
      app: :source_integration_app,
      version: "0.1.0",
      elixir: "~> 1.20",
      escript: [main_module: SourceIntegrationApp.Escript],
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

  defp verify_rustler_precompiled_target! do
    case System.get_env("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH") do
      nil ->
        :ok

      cache ->
        arch = System.fetch_env!("TARGET_ARCH")
        os = System.fetch_env!("TARGET_OS")
        abi = System.fetch_env!("TARGET_ABI")
        expected = "probe-#{arch}-#{os}-#{abi}.tar.gz"

        unless File.ls!(cache) == [expected] do
          raise "RustlerPrecompiled cache does not contain only the selected #{arch}-#{os}-#{abi} archive"
        end

        unless File.stat!(Path.join(cache, expected)).size > 0 do
          raise "selected RustlerPrecompiled archive is empty"
        end
    end
  end
end
