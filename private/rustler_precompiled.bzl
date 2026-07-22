"""Target-configured RustlerPrecompiled archive selection."""

RustlerPrecompiledArchiveInfo = provider(
    doc = "One target-selected archive staged in RustlerPrecompiled's offline cache.",
    fields = {
        "archive": "The selected archive File.",
        "archive_name": "The exact cache basename expected by the package's configured URL.",
        "target_abi": "The selected target ABI spelling: gnu or musl.",
        "target_arch": "The selected target architecture spelling.",
        "target_os": "The selected target operating-system spelling.",
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
    otp = ctx.toolchains["//:toolchain_type"].otpinfo
    target_abi = getattr(otp, "target_abi", "")
    target_arch = getattr(otp, "target_arch", "")
    target_os = getattr(otp, "target_os", "")
    if not target_abi or not target_arch or not target_os:
        fail("rustler_precompiled_archive requires target ABI, architecture, and OS metadata from the OTP toolchain")
    return [
        DefaultInfo(
            files = depset([archive]),
            runfiles = ctx.runfiles(files = [archive]),
        ),
        RustlerPrecompiledArchiveInfo(
            archive = archive,
            archive_name = archive_name,
            target_abi = target_abi,
            target_arch = target_arch,
            target_os = target_os,
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
    toolchains = ["//:toolchain_type"],
)
