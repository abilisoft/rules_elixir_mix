# SPDX-FileCopyrightText: 2026 AbiliSoft
# SPDX-License-Identifier: Apache-2.0

"""Immutable source-release catalog shipped with rules_elixir_mix."""

DEFAULT_OTP_VERSION = "29.0.3"
DEFAULT_ELIXIR_VERSION = "1.20.2"

_SOURCE_RELEASES = {
    "elixir": {
        "1.20.2": struct(
            archive_type = "tar.gz",
            sha256 = "1a25bbf9a9016651fc332eecc02bb9681d0b8e722c2e256e73ddb88fbce6e6b0",
            strip_prefix = "elixir-1.20.2",
            url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v1.20.2.tar.gz",
        ),
    },
    "otp": {
        "29.0.3": struct(
            archive_type = "tar.gz",
            sha256 = "edef13778a449490bc183134e442a955b134d69c56075d97765d8d4951d8d2bb",
            strip_prefix = "otp-OTP-29.0.3",
            url = "https://github.com/erlang/otp/archive/refs/tags/OTP-29.0.3.tar.gz",
        ),
    },
}

def known_source_versions(language):
    """Return source versions known by this pinned ruleset release.

    Args:
      language: The `otp` or `elixir` catalog to inspect.

    Returns:
      A sorted list of known version strings.
    """
    releases = _SOURCE_RELEASES.get(language)
    if releases == None:
        fail("unknown BEAM source language '{}'; expected otp or elixir".format(language))
    return sorted(releases.keys())

def resolve_source_release(
        language,
        version,
        url = "",
        sha256 = "",
        strip_prefix = "",
        archive_type = ""):
    """Resolve an immutable catalog entry or validate a complete custom override.

    A catalog lookup performs no network discovery. Its result is determined by
    the selected rules_elixir_mix module version. Custom sources must supply the
    URL and digest together so a moving archive can never enter the repository
    graph accidentally.

    Args:
      language: The `otp` or `elixir` catalog to inspect.
      version: The source release version recorded in the toolchain.
      url: An optional custom archive URL.
      sha256: The custom archive's SHA-256 digest.
      strip_prefix: The optional custom archive extraction prefix.
      archive_type: The optional custom archive type.

    Returns:
      A struct containing the resolved URL, digest, and extraction metadata.
    """
    releases = _SOURCE_RELEASES.get(language)
    if releases == None:
        fail("unknown BEAM source language '{}'; expected otp or elixir".format(language))

    if url or sha256:
        if not url or not sha256:
            fail("custom {} source {} must set both url and sha256".format(language, version))
        return struct(
            archive_type = archive_type,
            sha256 = sha256,
            strip_prefix = strip_prefix,
            url = url,
        )

    if strip_prefix or archive_type:
        fail("{} source {} may override strip_prefix or archive_type only with an explicit url and sha256".format(language, version))

    release = releases.get(version)
    if release == None:
        fail((
            "unknown {} source version '{}'; known versions are {}. " +
            "Set an explicit url and sha256 for a custom release."
        ).format(language, version, known_source_versions(language)))
    return release
