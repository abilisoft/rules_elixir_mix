"""Expose an extracted, hermetic Elixir runtime."""

load("//private:beam_info.bzl", "OtpInfo", "execution_erlexec", "execution_erts_bin", "otp_runtime_env", "path_join")
load("//private:elixir_info.bzl", "ElixirInfo", "otp_info_from_dependency")

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _elixir_prebuilt_release_impl(ctx):
    otp_info = otp_info_from_dependency(ctx.attr.otp)
    source_paths = {file.path: True for file in ctx.files.srcs}
    if ctx.file.home_marker.path not in source_paths or ctx.file.version_marker.path not in source_paths:
        fail("elixir_prebuilt_release home_marker and version_marker must be included in srcs")

    elixir_home = "/".join(ctx.file.home_marker.dirname.rsplit("/", 1)[:-1])
    elixir_home_short_path = ctx.file.home_marker.short_path.rsplit("/", 2)[0]
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")
    state = ctx.actions.declare_directory(ctx.label.name + "_verification_state")
    symlink_expression = "".join([
        "{ok,artifact_normalizer,N}=compile:file(",
        _erl_string(ctx.file._normalizer.path),
        ",[binary,report_errors,report_warnings])",
        ",{module,artifact_normalizer}=code:load_binary(artifact_normalizer,",
        _erl_string(ctx.file._normalizer.path),
        ",N)",
        ",ok=artifact_normalizer:assert_contained_symlinks(",
        _erl_string(elixir_home),
        ")",
    ])
    expression = "File.mkdir_p!({state});expected={expected};^expected=File.read!({marker})|>String.trim();^expected=System.version();File.write!({output},expected<>\"\\n\");File.rm_rf!({state});File.mkdir_p!({state})".format(
        expected = _erl_string(ctx.attr.version),
        marker = _erl_string(ctx.file.version_marker.path),
        output = _erl_string(version_file.path),
        state = _erl_string(state.path),
    )
    args = ctx.actions.args()
    args.add_all([
        "-noshell",
        "+fnu",
        "-eval",
        symlink_expression,
        "-s",
        "elixir",
        "start_cli",
        "-extra",
        "-e",
        expression,
    ])
    environment = otp_runtime_env(otp_info)
    environment.update({
        "ERL_LIBS": path_join(elixir_home, "lib"),
        "HOME": state.path + "/home",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": execution_erts_bin(otp_info),
        "RULES_ELIXIR_MIX_CRYPTO_STATE": state.path,
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = execution_erlexec(otp_info),
        arguments = [args],
        inputs = depset(
            direct = ctx.files.srcs + [ctx.file._normalizer],
            transitive = [otp_info.runtime_files],
        ),
        outputs = [version_file, state],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "ELIXIRVERIFY",
        use_default_shell_env = False,
    )
    runtime_files = depset(
        direct = ctx.files.srcs + [version_file],
        transitive = [ctx.attr.otp[DefaultInfo].files],
    )

    return [
        DefaultInfo(files = runtime_files),
        otp_info,
        ElixirInfo(
            version = ctx.attr.version,
            elixir_home = elixir_home,
            elixir_home_short_path = elixir_home_short_path,
            runtime_files = runtime_files,
            version_file = version_file,
        ),
    ]

elixir_prebuilt_release = rule(
    implementation = _elixir_prebuilt_release_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "All files in the extracted Elixir runtime.",
        ),
        "home_marker": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "A file at <elixir-home>/bin/<name>, used only to derive the archive root.",
        ),
        "version_marker": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The extracted runtime's VERSION file.",
        ),
        "otp": attr.label(
            mandatory = True,
            providers = [[OtpInfo], [platform_common.ToolchainInfo]],
        ),
        "_normalizer": attr.label(
            default = Label("//private:artifact_normalizer.erl"),
            allow_single_file = [".erl"],
        ),
    },
)
