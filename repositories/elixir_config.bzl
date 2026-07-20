"""Repository rule that emits selectable OTP+Elixir toolchains."""

INSTALLATION_TYPE_PREBUILT = "prebuilt"
INSTALLATION_TYPE_SOURCE = "source"

def _quote(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _list(values, indent = "        "):
    if not values:
        return ""
    return "".join([indent + _quote(value) + ",\n" for value in values])

def _installation(repository_ctx, name):
    installation_type = repository_ctx.attr.types[name]
    return struct(
        type = installation_type,
        otp_version = repository_ctx.attr.otp_versions[name],
        elixir_version = repository_ctx.attr.elixir_versions[name],
    )

def _prebuilt_build(repository_ctx, name, installation):
    repository_ctx.template(
        name + "/BUILD.bazel",
        Label("//repositories:BUILD_elixir_prebuilt.tpl"),
        substitutions = {
            "%{NAME}": name,
            "%{OTP_VERSION}": installation.otp_version,
            "%{OTP_RUNTIME}": repository_ctx.attr.otp_runtime_files[name],
            "%{ERLEXEC}": repository_ctx.attr.erlexec_files[name],
            "%{OTP_VERSION_MARKER}": repository_ctx.attr.otp_version_markers[name],
            "%{ELIXIR_VERSION}": installation.elixir_version,
            "%{ELIXIR_RUNTIME}": repository_ctx.attr.elixir_runtime_files[name],
            "%{ELIXIR_HOME_MARKER}": repository_ctx.attr.elixir_home_markers[name],
            "%{ELIXIR_VERSION_MARKER}": repository_ctx.attr.elixir_version_markers[name],
            "%{EXEC_CONSTRAINTS}": _list(repository_ctx.attr.exec_compatible_withs.get(name, [])),
            "%{TARGET_CONSTRAINTS}": _list(repository_ctx.attr.target_compatible_withs.get(name, [])),
            "%{FIPS}": repository_ctx.attr.fips_modes[name],
            "%{STATIC_CRYPTO_NIF}": repository_ctx.attr.static_crypto_nifs[name],
            "%{CRYPTO_SDK}": _optional_label(repository_ctx.attr.crypto_sdk_files.get(name, "")),
            "%{BASH}": _optional_label(repository_ctx.attr.bash_files.get(name, "")),
            "%{MAKE}": _optional_label(repository_ctx.attr.make_files.get(name, "")),
            "%{POSIX_TOOLS}": _list(repository_ctx.attr.posix_tool_files.get(name, [])),
            "%{PERL}": _optional_label(repository_ctx.attr.perl_files.get(name, "")),
        },
        executable = False,
    )

def _optional_label(value):
    return _quote(value) if value else "None"

def _source_build(repository_ctx, name, installation):
    repository_ctx.template(
        name + "/BUILD.bazel",
        Label("//repositories:BUILD_elixir_source.tpl"),
        substitutions = {
            "%{NAME}": name,
            "%{BOOTSTRAP_OTP_VERSION}": repository_ctx.attr.bootstrap_otp_versions[name],
            "%{BOOTSTRAP_RUNTIME}": repository_ctx.attr.bootstrap_runtime_files[name],
            "%{BOOTSTRAP_ERLEXEC}": repository_ctx.attr.bootstrap_erlexec_files[name],
            "%{BOOTSTRAP_VERSION_MARKER}": repository_ctx.attr.bootstrap_version_markers[name],
            "%{BOOTSTRAP_LAUNCHER}": repository_ctx.attr.bootstrap_launcher_files[name],
            "%{BOOTSTRAP_EXEC_CONSTRAINTS}": _list(repository_ctx.attr.bootstrap_exec_compatible_withs.get(name, [])),
            "%{OTP_VERSION}": installation.otp_version,
            "%{OTP_SOURCES}": repository_ctx.attr.otp_source_files[name],
            "%{OTP_SOURCE_DIRECTORIES}": repository_ctx.attr.otp_source_directory_manifests[name],
            "%{ELIXIR_VERSION}": installation.elixir_version,
            "%{ELIXIR_SOURCES}": repository_ctx.attr.elixir_source_files[name],
            "%{BASH}": repository_ctx.attr.bash_files[name],
            "%{MAKE}": repository_ctx.attr.make_files[name],
            "%{POSIX_TOOLS}": _list(repository_ctx.attr.posix_tool_files.get(name, [])),
            "%{PERL}": _optional_label(repository_ctx.attr.perl_files.get(name, "")),
            "%{CRYPTO_SDK}": _optional_label(repository_ctx.attr.crypto_sdk_files.get(name, "")),
            "%{CONFIGURE_OPTIONS}": _list(repository_ctx.attr.configure_options.get(name, [])),
            "%{MAKE_OPTIONS}": _list(repository_ctx.attr.make_options.get(name, [])),
            "%{COPTS}": _list(repository_ctx.attr.copts.get(name, [])),
            "%{CXXOPTS}": _list(repository_ctx.attr.cxxopts.get(name, [])),
            "%{LINKOPTS}": _list(repository_ctx.attr.linkopts.get(name, [])),
            "%{JOBS}": repository_ctx.attr.jobs[name],
            "%{ELIXIR_JOBS}": repository_ctx.attr.elixir_jobs[name],
            "%{ELIXIR_MAKE_OPTIONS}": _list(repository_ctx.attr.elixir_make_options.get(name, [])),
            "%{EXEC_CONSTRAINTS}": _list(repository_ctx.attr.exec_compatible_withs.get(name, [])),
            "%{TARGET_CONSTRAINTS}": _list(repository_ctx.attr.target_compatible_withs.get(name, [])),
            "%{FIPS}": repository_ctx.attr.fips_modes[name],
            "%{STATIC_CRYPTO_NIF}": repository_ctx.attr.static_crypto_nifs[name],
            "%{CROSS_COMPILE}": repository_ctx.attr.cross_compiles[name],
        },
        executable = False,
    )

def _root_build(names, default_name):
    values = "\n".join([
        """constraint_value(
    name = \"runtime_{name}\",
    constraint_setting = \":runtime\",
)""".format(name = name)
        for name in names
    ])
    return """package(default_visibility = [\"//visibility:public\"])

constraint_setting(
    name = \"runtime\",
    default_constraint_value = \":runtime_{default_name}\",
)

{values}
""".format(default_name = default_name, values = values)

def _elixir_config_impl(repository_ctx):
    names = sorted(repository_ctx.attr.types.keys())
    if not names:
        fail("elixir_config received no toolchains")

    for name in names:
        installation = _installation(repository_ctx, name)
        if installation.type == INSTALLATION_TYPE_PREBUILT:
            _prebuilt_build(repository_ctx, name, installation)
        elif installation.type == INSTALLATION_TYPE_SOURCE:
            _source_build(repository_ctx, name, installation)
        else:
            fail("unknown toolchain type '{}' for '{}'".format(installation.type, name))

    repository_ctx.file("BUILD.bazel", _root_build(names, repository_ctx.attr.default_name), executable = False)
    repository_ctx.file(
        "toolchains.bzl",
        "TOOLCHAINS = {}\n".format(repr([
            label
            for name in names
            for label in [
                "@{}//{}:otp_toolchain".format(repository_ctx.name, name),
                "@{}//{}:toolchain".format(repository_ctx.name, name),
            ]
        ])),
        executable = False,
    )

elixir_config = repository_rule(
    implementation = _elixir_config_impl,
    attrs = {
        "types": attr.string_dict(mandatory = True),
        "default_name": attr.string(mandatory = True),
        "otp_versions": attr.string_dict(),
        "bootstrap_otp_versions": attr.string_dict(),
        "bootstrap_runtime_files": attr.string_dict(),
        "bootstrap_erlexec_files": attr.string_dict(),
        "bootstrap_version_markers": attr.string_dict(),
        "bootstrap_launcher_files": attr.string_dict(),
        "bootstrap_exec_compatible_withs": attr.string_list_dict(),
        "otp_source_files": attr.string_dict(),
        "otp_source_directory_manifests": attr.string_dict(),
        "otp_runtime_files": attr.string_dict(),
        "erlexec_files": attr.string_dict(),
        "otp_version_markers": attr.string_dict(),
        "elixir_versions": attr.string_dict(),
        "elixir_runtime_files": attr.string_dict(),
        "elixir_home_markers": attr.string_dict(),
        "elixir_version_markers": attr.string_dict(),
        "elixir_source_files": attr.string_dict(),
        "bash_files": attr.string_dict(),
        "make_files": attr.string_dict(),
        "posix_tool_files": attr.string_list_dict(),
        "perl_files": attr.string_dict(),
        "crypto_sdk_files": attr.string_dict(),
        "fips_modes": attr.string_dict(),
        "static_crypto_nifs": attr.string_dict(),
        "cross_compiles": attr.string_dict(),
        "configure_options": attr.string_list_dict(),
        "make_options": attr.string_list_dict(),
        "copts": attr.string_list_dict(),
        "cxxopts": attr.string_list_dict(),
        "linkopts": attr.string_list_dict(),
        "jobs": attr.string_dict(),
        "elixir_jobs": attr.string_dict(),
        "elixir_make_options": attr.string_list_dict(),
        "exec_compatible_withs": attr.string_list_dict(),
        "target_compatible_withs": attr.string_list_dict(),
    },
)
