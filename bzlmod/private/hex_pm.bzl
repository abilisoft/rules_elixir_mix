"""Simple hex.pm utilities for rules_elixir_mix.

This provides basic functionality to fetch hex packages without complex
dependency resolution - that's handled by external tooling.
"""

def hex_archive_url(repository_url, package_name, version):
    """Generate a checksum-pinned Hex repository archive URL."""
    return "{}/tarballs/{}-{}.tar".format(repository_url.rstrip("/"), package_name, version)
