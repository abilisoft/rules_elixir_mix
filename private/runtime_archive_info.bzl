"""Providers for deterministic source-runtime archives."""

BeamRuntimeSourceInfo = provider(
    doc = "A relocatable runtime tree produced from pristine upstream sources.",
    fields = {
        "kind": "Runtime kind: otp or elixir.",
        "root": "Directory artifact containing the runtime image.",
        "root_relative_path": "Runtime root below the directory artifact.",
        "version": "Upstream runtime version.",
    },
)

BeamRuntimeArchiveInfo = provider(
    doc = "A deterministic runtime archive and its integrity metadata.",
    fields = {
        "archive": "Deterministic tar.gz archive.",
        "kind": "Runtime kind: otp or elixir.",
        "metadata": "Machine-readable archive and prebuilt-toolchain metadata.",
        "package_dir": "Top-level directory stored in the archive.",
        "sha256": "File containing the lowercase hexadecimal SHA-256 digest.",
        "version": "Upstream runtime version.",
    },
)
