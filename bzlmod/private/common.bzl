"""Shared helpers for generated Hex package BUILD files."""

MIX_BUILD_FILE_CONTENT = """\
package(default_visibility = ["//visibility:public"])

load("@rules_elixir_mix//:defs.bzl", "mix_library")

mix_library(
    name = "{app_name}",
    app_name = "{app_name}",
    hex_package = {package},
    hex_package_repository = {repository},
    hex_package_sha256 = {sha256},
    hex_package_version = {version},
{testonly_attr}    deps = {explicit_deps_str},
    compile_deps = {compile_deps_str},
    hex = "@hex_pm//:lib",
    priv = glob([
        "priv/**/*",
    ], allow_empty = True) + {precompiled_native_files_str},
    config = glob([
        "config/**/*.ex",
        "config/**/*.exs",
    ], allow_empty = True),
    # Hex archives are immutable and checksum-pinned. Declare the complete
    # archive so custom Mix compilers and compile-time asset readers cannot
    # acquire undeclared inputs.
    data = glob(["**"], exclude = ["BUILD.bazel"], allow_empty = True),
    include = glob([
        "include/**/*.hrl",
    ], allow_empty = True),
    srcs = glob([
        "lib/**/*.ex",
        "lib/**/*.exs",
        "src/**/*.app.src",
        "src/**/*.erl",
        "src/**/*.hrl",
        "src/**/*.xrl",
        "src/**/*.yrl",
    ], allow_empty = True),
    mix_config = ":mix.exs",
    native_build = {native_build},
    precompiled_native_artifacts = {precompiled_native_artifacts_str},
    # Third-party archives are immutable inputs; do not make consumers patch
    # upstream warnings just to use a package. First-party mix_library targets
    # keep warnings_as_errors enabled by default.
    warnings_as_errors = False,
)
"""

REBAR_BUILD_FILE_CONTENT = """\
package(default_visibility = ["//visibility:public"])

load("@rules_elixir_mix//:defs.bzl", "rebar_library")

rebar_library(
    name = "{app_name}",
    app_name = "{app_name}",
    hex_package = {package},
    hex_package_repository = {repository},
    hex_package_sha256 = {sha256},
    hex_package_version = {version},
    deps = {explicit_deps_str},
    compile_deps = {compile_deps_str},
    priv = glob(["priv/**/*"], allow_empty = True),
    include = glob(["include/**/*.hrl"], allow_empty = True),
    # Rebar plugins are rejected by the rule, but upstream compilation logic
    # may legitimately read any immutable archive file.
    srcs = glob(["**"], exclude = ["BUILD.bazel"], allow_empty = True),
    rebar_config = ":rebar.config",
    rebar3 = "@rebar3//file",
)
"""

def package_build_file_content(app_name, manager, explicit_deps_str, package, repository, sha256, version, compile_deps_str = "[]", native_build = False, precompiled_native_artifacts_str = "[]", precompiled_native_files_str = "[]", testonly_attr = ""):
    """Render a generated Hex package BUILD file for its declared manager.

    Args:
      app_name: OTP application name.
      manager: Mix lock manager atom, either `mix` or `rebar3`.
      explicit_deps_str: Rendered Bazel dependency-label list.
      package: Hex package name.
      repository: Hex repository identifier.
      sha256: Checksum-pinned Hex archive digest.
      version: Hex package version.
      compile_deps_str: Rendered compile-only dependency-label list.
      native_build: Whether the package may invoke a native source compiler.
      precompiled_native_artifacts_str: Rendered checksum-pinned native archive labels.
      precompiled_native_files_str: Rendered validated native files copied directly into priv.
      testonly_attr: Optional generated testonly attribute for Mix packages.

    Returns:
      Generated BUILD file content.
    """
    if manager == "mix":
        return MIX_BUILD_FILE_CONTENT.format(
            app_name = app_name,
            compile_deps_str = compile_deps_str,
            explicit_deps_str = explicit_deps_str,
            native_build = repr(native_build),
            package = repr(package),
            precompiled_native_artifacts_str = precompiled_native_artifacts_str,
            precompiled_native_files_str = precompiled_native_files_str,
            repository = repr(repository),
            sha256 = repr(sha256),
            testonly_attr = testonly_attr,
            version = repr(version),
        )
    if manager == "rebar3":
        return REBAR_BUILD_FILE_CONTENT.format(
            app_name = app_name,
            compile_deps_str = compile_deps_str,
            explicit_deps_str = explicit_deps_str,
            package = repr(package),
            repository = repr(repository),
            sha256 = repr(sha256),
            version = repr(version),
        )
    fail("unsupported Hex build manager '{}' for {}".format(manager, app_name))

def format_deps_str(deps_list):
    quoted_strings = [
        "\"{}\"".format(dep)
        for dep in deps_list
    ]

    return "[" + ", ".join(quoted_strings) + "]"
