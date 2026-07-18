"""Expose an extracted, hermetic Erlang/OTP runtime."""

load("//private:beam_info.bzl", "OtpInfo", "fips_erl_args", "otp_runtime_env")
load("//private:otp_crypto_sdk.bzl", "crypto_sdk_info")

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _otp_prebuilt_release_impl(ctx):
    crypto = crypto_sdk_info(ctx.attr.crypto_sdk)
    if ctx.attr.fips == "required":
        if int(ctx.attr.version.split(".")[0]) < 29:
            fail("FIPS-required statically linked crypto requires OTP 29 or newer")
        if not crypto:
            fail("FIPS-required prebuilt OTP must declare its crypto_sdk contract")
        if not ctx.attr.static_crypto_nif:
            fail("FIPS-required prebuilt OTP must declare static_crypto_nif=True")
    source_paths = {file.path: True for file in ctx.files.srcs}
    if ctx.file.erlexec.path not in source_paths:
        fail("otp_prebuilt_release erlexec must be included in srcs")
    if ctx.file.version_marker.path not in source_paths:
        fail("otp_prebuilt_release version_marker must be included in srcs")

    # erlexec is below <erlang-home>/erts-<version>/bin. Deriving both paths
    # from the native executable avoids OTP's bin/erl shell launcher.
    erlang_home = ctx.file.erlexec.path.rsplit("/", 3)[0]
    erlang_home_short_path = ctx.file.erlexec.short_path.rsplit("/", 3)[0]
    erts_bin = ctx.file.erlexec.dirname
    erts_bin_short_path = ctx.file.erlexec.short_path.rsplit("/", 1)[0]
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")
    state = version_file.path + ".state"
    crypto_checks = []
    if ctx.attr.static_crypto_nif or ctx.attr.fips == "required":
        crypto_checks.extend([
            ",{ok,_}=application:ensure_all_started(crypto)",
            ",#{link_type:=static}=crypto:info()",
        ])
    if ctx.attr.fips == "required":
        crypto_checks.extend([
            ",enabled=crypto:info_fips()",
            ",32=byte_size(crypto:hash(sha256,<<\"rules_elixir_mix\">>))",
            ",{'EXIT',_}=catch crypto:hash(md5,<<\"must fail\">>)",
        ])
    expression = "".join([
        "E=",
        _erl_string(ctx.attr.version),
        ",{ok,B}=file:read_file(",
        _erl_string(ctx.file.version_marker.path),
        ")",
        ",E=string:trim(binary_to_list(B))",
        ",M=hd(string:tokens(E,\".\"))",
        ",M=erlang:system_info(otp_release)",
    ] + crypto_checks + [
        ",ok=file:write_file(",
        _erl_string(version_file.path),
        ",[E,10])",
        ",case file:del_dir_r(",
        _erl_string(state),
        ") of ok->ok;{error,enoent}->ok end",
        ",halt().",
    ])
    args = ctx.actions.args()
    args.add_all(
        ["-noshell"] +
        fips_erl_args(struct(fips = ctx.attr.fips, crypto_sdk = crypto)) +
        ["-eval", expression],
    )
    environment = otp_runtime_env(struct(
        erlang_home = erlang_home,
        erts_bin = erts_bin,
    ))
    environment.update({
        "HOME": state + "/home",
        "LANG": "C",
        "LC_ALL": "C",
        "RULES_ELIXIR_MIX_CRYPTO_STATE": state,
        "TZ": "UTC",
    })
    crypto_inputs = depset(
        direct = [crypto.sysroot],
        transitive = [crypto.exec_files],
    ) if crypto and crypto.activation_exec_tool else depset()
    ctx.actions.run(
        executable = ctx.file.erlexec,
        arguments = [args],
        inputs = depset(
            direct = ctx.files.srcs,
            transitive = [crypto_inputs],
        ),
        tools = [crypto.activation_exec_tool] if crypto and crypto.activation_exec_tool else [],
        outputs = [version_file],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "OTPVERIFY",
        use_default_shell_env = False,
    )
    runtime_files = depset(direct = ctx.files.srcs + [version_file])

    return [
        DefaultInfo(files = runtime_files),
        OtpInfo(
            version = ctx.attr.version,
            crypto_sdk = crypto,
            erlang_home = erlang_home,
            erlang_home_short_path = erlang_home_short_path,
            erl = ctx.file.erlexec,
            erlexec = ctx.file.erlexec,
            erts_bin = erts_bin,
            erts_bin_short_path = erts_bin_short_path,
            fips = ctx.attr.fips,
            runtime_files = runtime_files,
            static_crypto_nif = ctx.attr.static_crypto_nif,
            version_file = version_file,
        ),
    ]

otp_prebuilt_release = rule(
    implementation = _otp_prebuilt_release_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "crypto_sdk": attr.label(allow_files = True),
        "fips": attr.string(default = "disabled", values = ["disabled", "required"]),
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "All files in the extracted OTP runtime.",
        ),
        "erlexec": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The runtime's native erts-<version>/bin/erlexec executable.",
        ),
        "version_marker": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Installed releases/<major>/OTP_VERSION file.",
        ),
        "static_crypto_nif": attr.bool(default = False),
    },
)
