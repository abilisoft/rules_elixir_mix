"""Checksum-pinned source archive repository with directory topology metadata."""

load("//:repository_integrity.bzl", "validate_extracted_tree")

_BUILD_FILE = """package(default_visibility = ["//visibility:public"])

exports_files(["source_directories.manifest"])

filegroup(
    name = "runtime",
    srcs = glob(
        ["**"],
        exclude = ["BUILD.bazel", "source_directories.manifest"],
    ),
)
"""

def _directory_manifest(root):
    directories = []
    pending = [(root, "")]
    for _depth in range(256):
        if not pending:
            break
        next_pending = []
        for current, relative in pending:
            for entry in current.readdir(watch = "no"):
                child_relative = entry.basename if not relative else relative + "/" + entry.basename
                if entry.is_dir and str(entry.realpath) == str(entry):
                    directories.append(child_relative)
                    next_pending.append((entry, child_relative))
        pending = next_pending
    if pending:
        fail("source archive directory nesting exceeds 256 levels")
    return "\n".join(sorted(directories)) + "\n"

def _source_archive_impl(repository_ctx):
    if repository_ctx.attr.build_file and repository_ctx.attr.build_file_content:
        fail("build_file and build_file_content are mutually exclusive")
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        output = "",
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
        type = repository_ctx.attr.archive_type,
    )
    validate_extracted_tree(repository_ctx)
    root = repository_ctx.path(".")
    repository_ctx.file(
        "source_directories.manifest",
        _directory_manifest(root),
        executable = False,
    )
    build_file_content = _BUILD_FILE
    if repository_ctx.attr.build_file:
        build_file_content = repository_ctx.read(repository_ctx.attr.build_file)
    elif repository_ctx.attr.build_file_content:
        build_file_content = repository_ctx.attr.build_file_content
    repository_ctx.file("BUILD.bazel", build_file_content, executable = False)

source_archive = repository_rule(
    implementation = _source_archive_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "archive_type": attr.string(),
        "build_file": attr.label(allow_single_file = True),
        "build_file_content": attr.string(),
    },
)
