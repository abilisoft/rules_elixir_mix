"""Target-configured RustlerPrecompiled archive selection."""

RustlerPrecompiledArchiveInfo = provider(
    doc = "One target-selected archive staged in RustlerPrecompiled's offline cache.",
    fields = {
        "archive": "The selected archive File.",
        "archive_name": "The exact cache basename expected by the package's configured URL.",
    },
)

def _rustler_precompiled_archive_impl(ctx):
    files = ctx.attr.archive[DefaultInfo].files.to_list()
    if len(files) != 1 or files[0].is_directory:
        fail("rustler_precompiled_archive archive must select exactly one regular file")
    archive = files[0]
    archive_name = ctx.attr.archive_name or archive.basename
    if archive_name in ["", ".", ".."] or "/" in archive_name or "\\" in archive_name:
        fail("rustler_precompiled_archive archive_name must be a basename")
    return [
        DefaultInfo(
            files = depset([archive]),
            runfiles = ctx.runfiles(files = [archive]),
        ),
        RustlerPrecompiledArchiveInfo(
            archive = archive,
            archive_name = archive_name,
        ),
    ]

rustler_precompiled_archive = rule(
    implementation = _rustler_precompiled_archive_impl,
    attrs = {
        "archive": attr.label(mandatory = True, allow_files = True),
        "archive_name": attr.string(
            doc = "Optional cache basename when the selected Bazel file name differs from the upstream URL basename.",
        ),
    },
    doc = "Selects one checksum-owned RustlerPrecompiled archive in the target configuration.",
)
