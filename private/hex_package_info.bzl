"""Providers and helpers for checksum-pinned Hex package source trees."""

HexPackageInfo = provider(
    doc = "Lock-owned Hex archive identity and package-relative source mappings.",
    fields = {
        "app_name": "OTP application name exposed by the generated dependency target.",
        "files": "Depset containing every declared source file extracted from the locked archive.",
        "package": "Hex package name recorded in mix.lock.",
        "project_entries": "Stable package-relative source mappings.",
        "repository": "Hex repository identifier recorded by the lock importer.",
        "sha256": "Checksum-pinned Hex archive digest from mix.lock.",
        "version": "Hex package version from mix.lock.",
    },
)

def hex_package_info(ctx, app_name, project_entries, project_files):
    """Return lock-owned package metadata when the generated attributes are set.

    Args:
      ctx: Rule context containing the generated Hex identity attributes.
      app_name: OTP application name exposed by the package target.
      project_entries: Stable package-relative source mappings.
      project_files: Declared files extracted from the locked archive.

    Returns:
      HexPackageInfo for a lock-generated package, or None for ordinary targets.
    """
    identity = [
        ctx.attr.hex_package,
        ctx.attr.hex_package_version,
        ctx.attr.hex_package_sha256,
        ctx.attr.hex_package_repository,
    ]
    if not any(identity):
        return None
    if not all(identity):
        fail("Hex package identity attributes must be declared together for {}".format(ctx.label))
    if len(ctx.attr.hex_package_sha256) != 64:
        fail("Hex package SHA-256 must contain 64 hexadecimal characters for {}".format(ctx.label))
    hexadecimal = "0123456789abcdefABCDEF"
    if any([
        ctx.attr.hex_package_sha256[index] not in hexadecimal
        for index in range(len(ctx.attr.hex_package_sha256))
    ]):
        fail("Hex package SHA-256 is not hexadecimal for {}".format(ctx.label))
    return HexPackageInfo(
        app_name = app_name,
        files = depset(project_files),
        package = ctx.attr.hex_package,
        project_entries = project_entries,
        repository = ctx.attr.hex_package_repository,
        sha256 = ctx.attr.hex_package_sha256.lower(),
        version = ctx.attr.hex_package_version,
    )

HEX_PACKAGE_ATTRS = {
    "hex_package": attr.string(doc = "Hex package name for a lock-generated target."),
    "hex_package_repository": attr.string(doc = "Hex repository identifier for a lock-generated target."),
    "hex_package_sha256": attr.string(doc = "Checksum-pinned Hex archive digest for a lock-generated target."),
    "hex_package_version": attr.string(doc = "Hex package version for a lock-generated target."),
}
