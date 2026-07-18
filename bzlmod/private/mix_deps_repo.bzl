"""Repository hub exposing a Mix lock graph through one use_repo entry."""

def _quote(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _mix_deps_repo_impl(repository_ctx):
    aliases = []
    for name in sorted(repository_ctx.attr.packages.keys()):
        aliases.append("""alias(
    name = {name},
    actual = {actual},
)
""".format(
            name = _quote(name),
            actual = _quote(repository_ctx.attr.packages[name]),
        ))
    repository_ctx.file(
        "BUILD.bazel",
        "package(default_visibility = [\"//visibility:public\"])\n\n" + "\n".join(aliases),
        executable = False,
    )

mix_deps_repo = repository_rule(
    implementation = _mix_deps_repo_impl,
    attrs = {"packages": attr.string_dict(mandatory = True)},
)
