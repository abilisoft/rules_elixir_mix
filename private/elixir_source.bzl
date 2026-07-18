"""Declared mappings for Bazel-generated Mix project sources."""

ElixirSourceInfo = provider(
    doc = "Generated files mapped to stable logical paths in a Mix project.",
    fields = {
        "entries": "List of structs with source File and project-relative destination.",
    },
)

def _validate_destination(destination):
    if not destination or destination.startswith("/"):
        fail("elixir_generated_source destination must be a non-empty relative path")
    if "\\" in destination:
        fail("elixir_generated_source destination must use forward slashes")
    for part in destination.split("/"):
        if part in ["", ".", ".."]:
            fail("elixir_generated_source destination must not contain empty, '.' or '..' segments")

def _elixir_generated_source_impl(ctx):
    _validate_destination(ctx.attr.destination)
    source = ctx.file.src
    return [
        DefaultInfo(files = depset([source]), runfiles = ctx.runfiles(files = [source])),
        ElixirSourceInfo(entries = [struct(
            destination = ctx.attr.destination,
            source = source,
        )]),
    ]

elixir_generated_source = rule(
    implementation = _elixir_generated_source_impl,
    attrs = {
        "destination": attr.string(mandatory = True),
        "src": attr.label(mandatory = True, allow_single_file = True),
    },
)
