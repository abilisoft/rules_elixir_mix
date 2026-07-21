"""Hermetic repository rule for checksum-pinned Hex packages."""

load("//:repository_integrity.bzl", "validate_extracted_tree")
load(":hex_pm.bzl", "hex_archive_url")

def _strip_level(patch_args):
    strip = 0
    for arg in patch_args:
        if arg.startswith("-p"):
            strip = int(arg[2:])
        else:
            fail("hex_archive supports only -pN patch arguments, got '{}'".format(arg))
    return strip

def _hex_archive_impl(repository_ctx):
    repository_ctx.download(
        url = hex_archive_url(
            repository_ctx.attr.repository_url,
            repository_ctx.attr.package_name,
            repository_ctx.attr.version,
        ),
        output = "hex-package.tar",
        sha256 = repository_ctx.attr.sha256,
    )
    repository_ctx.extract("hex-package.tar")
    repository_ctx.extract("contents.tar.gz")
    validate_extracted_tree(repository_ctx)
    repository_ctx.delete("hex-package.tar")
    repository_ctx.delete("contents.tar.gz")

    inner_checksum = repository_ctx.read("CHECKSUM").strip().lower()
    repository_ctx.file(
        ".hex",
        "{},{},{},{}\n{}\n".format(
            repository_ctx.attr.package_name,
            repository_ctx.attr.version,
            inner_checksum,
            repository_ctx.attr.repository_name,
            repository_ctx.attr.manager,
        ),
    )

    strip = _strip_level(repository_ctx.attr.patch_args)
    for patch_file in repository_ctx.attr.patches:
        repository_ctx.patch(patch_file, strip = strip)

    if repository_ctx.attr.build_file:
        repository_ctx.symlink(repository_ctx.attr.build_file, "BUILD.bazel")
    elif repository_ctx.attr.build_file_content:
        repository_ctx.file("BUILD.bazel", repository_ctx.attr.build_file_content)
    else:
        fail("hex_archive requires build_file or build_file_content")

hex_archive = repository_rule(
    implementation = _hex_archive_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "repository_name": attr.string(mandatory = True),
        "repository_url": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "manager": attr.string(mandatory = True, values = ["mix", "rebar3"]),
        "build_file": attr.label(allow_single_file = True),
        "build_file_content": attr.string(),
        "patches": attr.label_list(allow_files = True),
        "patch_args": attr.string_list(default = ["-p0"]),
    },
)
