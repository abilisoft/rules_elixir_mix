# SPDX-FileCopyrightText: 2026 AbiliSoft
# SPDX-License-Identifier: Apache-2.0

Code.require_file("source_catalog.ex", __DIR__)

catalog = Path.expand("../bzlmod/versions.bzl", __DIR__)
releases = RulesElixirMix.SourceCatalog.refresh(catalog, System.get_env("GITHUB_TOKEN"))

case releases do
  [] ->
    IO.puts("OTP and Elixir source defaults are current")

  releases ->
    versions = Enum.map_join(releases, ", ", &"#{&1.language} #{&1.version}")
    IO.puts("updated source catalog: #{versions}")
end
