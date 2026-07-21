"""Public projection of lock-owned Hex package files."""

load("//private:hex_package_info.bzl", "HexPackageInfo")

HexPackageAssetsInfo = provider(
    doc = "Selected source assets and immutable identity of their owning Hex archive.",
    fields = {
        "files": "Depset of selected source assets.",
        "package": "Hex package name.",
        "paths": "Requested package-relative paths in declaration order.",
        "repository": "Hex repository identifier.",
        "sha256": "Checksum-pinned Hex archive digest.",
        "version": "Hex package version.",
    },
)

def _validate_path(path):
    if not path or path.startswith("/") or "\\" in path:
        fail("Hex package asset paths must be non-empty package-relative POSIX paths: '{}'".format(path))
    if any([part in ["", ".", ".."] for part in path.split("/")]):
        fail("Hex package asset path is not normalized: '{}'".format(path))

def _hex_package_assets_impl(ctx):
    package = ctx.attr.package[HexPackageInfo]
    if not ctx.attr.paths:
        fail("hex_package_assets requires at least one package-relative path")
    entries = {}
    for entry in package.project_entries:
        if entry.destination in entries and entries[entry.destination].path != entry.source.path:
            fail("Hex package '{}' exposes multiple files at '{}'".format(package.package, entry.destination))
        entries[entry.destination] = entry.source

    selected = []
    seen = {}
    for path in ctx.attr.paths:
        _validate_path(path)
        if path in seen:
            fail("Hex package asset path '{}' is declared more than once".format(path))
        seen[path] = True
        if path not in entries:
            fail("Hex package '{} {}' does not contain asset '{}'".format(package.package, package.version, path))
        projected = ctx.actions.declare_file(
            "{}_locked_{}/{}".format(ctx.label.name, package.sha256, path),
        )
        ctx.actions.symlink(
            output = projected,
            target_file = entries[path],
        )
        selected.append(projected)

    files = depset(selected)
    return [
        DefaultInfo(files = files, runfiles = ctx.runfiles(files = selected)),
        HexPackageAssetsInfo(
            files = files,
            package = package.package,
            paths = ctx.attr.paths,
            repository = package.repository,
            sha256 = package.sha256,
            version = package.version,
        ),
    ]

hex_package_assets = rule(
    implementation = _hex_package_assets_impl,
    attrs = {
        "package": attr.label(mandatory = True, providers = [HexPackageInfo]),
        "paths": attr.string_list(mandatory = True),
    },
    doc = "Expose exact package-relative files from a checksum-pinned Hex dependency target.",
)
