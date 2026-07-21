"""Checksum-pinned prebuilt runtime archive with repository-tree validation."""

load("//:repository_integrity.bzl", "validate_extracted_tree")

_BUILD_FILE = """package(default_visibility = [\"//visibility:public\"])

exports_files({exported_files})

filegroup(
    name = \"runtime\",
    srcs = glob([\"**\"], exclude = [\"BUILD.bazel\"]),
)
"""

def _prebuilt_archive_impl(repository_ctx):
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        output = "",
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
        type = repository_ctx.attr.archive_type,
    )
    validate_extracted_tree(repository_ctx)
    repository_ctx.file(
        "BUILD.bazel",
        _BUILD_FILE.format(exported_files = repr(repository_ctx.attr.exported_files)),
        executable = False,
    )

prebuilt_archive = repository_rule(
    implementation = _prebuilt_archive_impl,
    attrs = {
        "archive_type": attr.string(),
        "exported_files": attr.string_list(),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "urls": attr.string_list(mandatory = True),
    },
)
