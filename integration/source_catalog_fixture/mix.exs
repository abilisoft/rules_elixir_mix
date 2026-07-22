defmodule RulesElixirMix.SourceCatalog.MixProject do
  use Mix.Project

  def project do
    verify_rustler_precompiled_target!()

    [
      app: :rules_elixir_mix_source_catalog,
      elixir: "~> 1.20",
      version: "0.0.0"
    ]
  end

  defp verify_rustler_precompiled_target! do
    if System.get_env("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH") do
      system_architecture = :erlang.system_info(:system_architecture) |> to_string()

      expected_arch =
        cond do
          String.starts_with?(system_architecture, "x86_64") -> "x86_64"
          String.starts_with?(system_architecture, "aarch64") -> "aarch64"
          true -> nil
        end

      expected = %{
        "TARGET_ABI" => "gnu",
        "TARGET_ARCH" => expected_arch,
        "TARGET_OS" => "linux",
        "TARGET_VENDOR" => "unknown"
      }

      Enum.each(expected, fn {name, value} ->
        if value && System.fetch_env!(name) != value do
          raise "#{name} does not describe the selected Bazel target"
        end
      end)
    end
  end
end
