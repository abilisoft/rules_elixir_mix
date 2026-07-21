# SPDX-FileCopyrightText: 2026 AbiliSoft
# SPDX-License-Identifier: Apache-2.0

unless Code.ensure_loaded?(RulesElixirMix.SourceCatalog) do
  Code.require_file("source_catalog.ex", __DIR__)
end

ExUnit.start()

defmodule RulesElixirMix.SourceCatalogTest do
  use ExUnit.Case, async: true

  alias RulesElixirMix.SourceCatalog

  @catalog """
  DEFAULT_OTP_VERSION = "29.0.3"
  DEFAULT_ELIXIR_VERSION = "1.20.2"

  _SOURCE_RELEASES = {
      "elixir": {
          "1.20.2": struct(
              archive_type = "tar.gz",
              sha256 = "elixir-old",
              strip_prefix = "elixir-1.20.2",
              url = "https://example.invalid/elixir-old.tar.gz",
          ),
      },
      "otp": {
          "29.0.3": struct(
              archive_type = "tar.gz",
              sha256 = "otp-old",
              strip_prefix = "otp-OTP-29.0.3",
              url = "https://example.invalid/otp-old.tar.gz",
          ),
      },
  }
  """

  test "adds an immutable release, changes the default, and preserves history" do
    release = SourceCatalog.release_from_tag("otp", "OTP-29.0.4", String.duplicate("a", 64))
    updated = SourceCatalog.update_catalog(@catalog, [release])

    assert SourceCatalog.current_default(updated, "otp") == "29.0.4"
    assert SourceCatalog.catalog_contains?(updated, "otp", "29.0.4")
    assert SourceCatalog.catalog_contains?(updated, "otp", "29.0.3")
    assert updated =~ "https://github.com/erlang/otp/archive/refs/tags/OTP-29.0.4.tar.gz"
    assert updated =~ "strip_prefix = \"otp-OTP-29.0.4\""
  end

  test "promotes an existing release without duplicating it" do
    release = SourceCatalog.release_from_tag("elixir", "v1.20.2")
    updated = SourceCatalog.update_catalog(@catalog, [release])

    assert SourceCatalog.current_default(updated, "elixir") == "1.20.2"
    assert length(:binary.matches(updated, "\"1.20.2\": struct(")) == 1
  end

  test "catalog updates are idempotent" do
    release = SourceCatalog.release_from_tag("elixir", "v1.21.0", String.duplicate("b", 64))
    updated = SourceCatalog.update_catalog(@catalog, [release])

    assert SourceCatalog.update_catalog(updated, [release]) == updated
  end

  test "rejects non-stable or unexpected release tags" do
    assert_raise ArgumentError, fn ->
      SourceCatalog.release_from_tag("otp", "OTP-30.0-rc1")
    end

    assert_raise ArgumentError, fn ->
      SourceCatalog.release_from_tag("elixir", "main")
    end
  end

  test "requires a valid digest before adding a release" do
    release = SourceCatalog.release_from_tag("otp", "OTP-29.0.4")

    assert_raise ArgumentError, fn ->
      SourceCatalog.update_catalog(@catalog, [release])
    end
  end

  test "does not confuse equal-looking versions across language sections" do
    refute SourceCatalog.catalog_contains?(@catalog, "otp", "1.20.2")
    refute SourceCatalog.catalog_contains?(@catalog, "elixir", "29.0.3")
  end
end
