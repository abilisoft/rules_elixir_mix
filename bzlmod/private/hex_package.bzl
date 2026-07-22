"""Simple Hex package extension for rules_elixir_mix.

This extension fetches hex packages with pre-resolved dependencies.
Dependency resolution is handled by external tooling.
"""

load(":common.bzl", "format_deps_str", "package_build_file_content")
load(":hex_archive.bzl", "hex_archive")

def hex_package_repo(name, pkg, version, sha256, integrity, build_file, build_file_content, patches, patch_args, explicit_deps = [], compile_deps = [], native_build = False, precompiled_native_artifacts = [], precompiled_native_files = [], rustler_precompiled_artifacts = [], manager = "mix", repository_name = "hexpm", repository_url = "https://repo.hex.pm"):
    """Create a hex_archive repository for a package.

    Args:
      name: Repository name to create.
      pkg: Hex package name, or empty to use name.
      version: Hex package version.
      sha256: Expected archive SHA256.
      integrity: Reserved integrity value; currently unsupported.
      build_file: Optional custom BUILD file label.
      build_file_content: Optional custom BUILD file content.
      patches: Patches to apply to the archive.
      patch_args: Patch command arguments.
      explicit_deps: Dependency labels for the generated mix_library.
      compile_deps: Compile-only dependency labels for the generated rule.
      native_build: Whether the package may invoke a native source compiler.
      precompiled_native_artifacts: Checksum-pinned archives staged for ElixirMake.
      precompiled_native_files: Validated native files copied directly into package priv.
      rustler_precompiled_artifacts: Target-selected archives staged in RustlerPrecompiled's offline cache.
      manager: Generated package build manager, `mix` or `rebar3`.
      repository_name: Repository identifier stored in Hex metadata.
      repository_url: Explicit base URL used to fetch the archive.
    """
    package_name = pkg if pkg else name
    if (precompiled_native_artifacts or precompiled_native_files or rustler_precompiled_artifacts) and manager != "mix":
        fail("precompiled native inputs are only supported for Mix package {}".format(name))
    if len([value for value in [precompiled_native_artifacts, precompiled_native_files, rustler_precompiled_artifacts] if value]) > 1:
        fail("package {} must select exactly one precompiled native cache/file mechanism".format(name))
    if integrity:
        fail("hex_package {} uses integrity; rules_elixir_mix currently requires sha256".format(name))
    if not sha256:
        fail("hex_package {} must set sha256".format(name))

    if build_file:
        if explicit_deps or compile_deps or native_build or precompiled_native_artifacts or precompiled_native_files or rustler_precompiled_artifacts:
            fail("generated dependency/native attributes and build_file are mutually exclusive")
        hex_archive(
            name = name,
            package_name = package_name,
            repository_name = repository_name,
            repository_url = repository_url,
            version = version,
            sha256 = sha256,
            manager = manager,
            build_file = build_file,
            patches = patches,
            patch_args = patch_args,
        )
    elif build_file_content:
        if explicit_deps or compile_deps or native_build or precompiled_native_artifacts or precompiled_native_files or rustler_precompiled_artifacts:
            fail("generated dependency/native attributes and build_file_content are mutually exclusive")

        hex_archive(
            name = name,
            package_name = package_name,
            repository_name = repository_name,
            repository_url = repository_url,
            version = version,
            sha256 = sha256,
            manager = manager,
            build_file_content = build_file_content,
            patches = patches,
            patch_args = patch_args,
        )
    else:
        # Generate default BUILD file for mix projects
        hex_archive(
            name = name,
            package_name = package_name,
            repository_name = repository_name,
            repository_url = repository_url,
            version = version,
            sha256 = sha256,
            manager = manager,
            build_file_content = package_build_file_content(
                app_name = package_name,
                compile_deps_str = format_deps_str(compile_deps),
                manager = manager,
                native_build = native_build,
                package = package_name,
                explicit_deps_str = format_deps_str(explicit_deps),
                precompiled_native_artifacts_str = format_deps_str(precompiled_native_artifacts),
                precompiled_native_files_str = format_deps_str(precompiled_native_files),
                rustler_precompiled_artifacts_str = format_deps_str(rustler_precompiled_artifacts),
                repository = repository_name,
                sha256 = sha256,
                version = version,
            ),
            patches = patches,
            patch_args = patch_args,
        )

# Tag class for hex_package declarations
hex_package_tag = tag_class(attrs = {
    "name": attr.string(mandatory = True, doc = "Name of the package"),
    "pkg": attr.string(doc = "Package name on hex.pm (if different from name)"),
    "version": attr.string(mandatory = True, doc = "Version of the package"),
    "sha256": attr.string(doc = "Expected SHA256 of the package archive. Mutually exclusive with integrity."),
    "integrity": attr.string(doc = "Reserved for future support; use sha256."),
    "build_file": attr.label(doc = "Custom BUILD file for the package"),
    "build_file_content": attr.string(doc = "Custom BUILD file content for the package"),
    "patches": attr.label_list(default = [], doc = "Patches to apply to the package"),
    "patch_args": attr.string_list(default = ["-p0"], doc = "Arguments for patch command"),
    "compile_deps": attr.string_list(default = [], doc = "Explicit compile-only dependency labels for the generated target"),
    "explicit_deps": attr.string_list(default = [], doc = "Explicit dependency labels to use in the generated mix_library deps list"),
    "manager": attr.string(default = "mix", values = ["mix", "rebar3"], doc = "Generated package build manager"),
    "native_build": attr.bool(default = False, doc = "Allow the generated Mix target to use the selected native build closure"),
    "precompiled_native_artifacts": attr.label_list(allow_files = True, default = [], doc = "Checksum-pinned archives staged in ElixirMake's isolated cache"),
    "precompiled_native_files": attr.label_list(allow_files = True, default = [], doc = "Validated native files copied directly into package priv"),
    "rustler_precompiled_artifacts": attr.label_list(allow_files = True, default = [], doc = "Target-selected archives staged in RustlerPrecompiled's offline cache"),
    "repository_name": attr.string(default = "hexpm", doc = "Hex repository identifier"),
    "repository_url": attr.string(default = "https://repo.hex.pm", doc = "Explicit Hex repository base URL"),
})
