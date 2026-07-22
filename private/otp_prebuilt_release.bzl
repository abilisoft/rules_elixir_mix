"""Expose an extracted, hermetic Erlang/OTP runtime."""

load("//private:beam_info.bzl", "OtpInfo", "crypto_runtime_files", "erl_env_flags", "execution_erlexec_file", "fips_erl_args", "otp_runtime_env", "otp_runtime_erl_args", "prepare_crypto_runtime")
load("//private:otp_crypto_sdk.bzl", "crypto_sdk_info")

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _otp_prebuilt_release_impl(ctx):
    crypto = crypto_sdk_info(ctx.attr.crypto_sdk)
    if ctx.attr.fully_static == ctx.attr.runtime_wrapped:
        fail(
            "otp_prebuilt_release must declare exactly one runtime contract: " +
            "fully_static=True or runtime_wrapped=True",
        )
    if ctx.attr.runtime_wrapped and not (
        crypto and crypto.execution_wrapper and crypto.execution_exec_wrapper
    ):
        fail("runtime_wrapped=True requires a crypto SDK with target and execution wrappers")
    if ctx.attr.fully_static and crypto and crypto.execution_exec_wrapper:
        fail("a fully static prebuilt OTP must not declare a dynamic SDK execution wrapper")
    if ctx.attr.fips == "required":
        if int(ctx.attr.version.split(".")[0]) < 29:
            fail("FIPS-capable statically linked crypto requires OTP 29 or newer")
        if not crypto:
            fail("FIPS-required prebuilt OTP must declare its crypto_sdk contract")
        if not ctx.attr.static_crypto_nif:
            fail("FIPS-required prebuilt OTP must declare static_crypto_nif=True")
    source_paths = {file.path: True for file in ctx.files.srcs}
    if ctx.file.erlexec.path not in source_paths:
        fail("otp_prebuilt_release erlexec must be included in srcs")
    if ctx.file.version_marker.path not in source_paths:
        fail("otp_prebuilt_release version_marker must be included in srcs")
    if ctx.file.boot_file:
        if ctx.file.boot_file.path not in source_paths:
            fail("otp_prebuilt_release boot_file must be included in srcs")
        if not ctx.file.boot_file.path.endswith(".boot"):
            fail("otp_prebuilt_release boot_file must end in .boot")

    # erlexec is below <erlang-home>/erts-<version>/bin. Deriving both paths
    # from the native executable avoids OTP's bin/erl shell launcher.
    erlang_home = ctx.file.erlexec.path.rsplit("/", 3)[0]
    erlang_home_short_path = ctx.file.erlexec.short_path.rsplit("/", 3)[0]
    erts_bin = ctx.file.erlexec.dirname
    erts_bin_short_path = ctx.file.erlexec.short_path.rsplit("/", 1)[0]
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")
    state = version_file.path + ".state"
    otp_contract = struct(
        boot_file = ctx.file.boot_file,
        boot_file_short_path = ctx.file.boot_file.short_path if ctx.file.boot_file else "",
        crypto_sdk = crypto,
        erlang_home = erlang_home,
        erlang_home_short_path = erlang_home_short_path,
        erlexec = ctx.file.erlexec,
        erts_bin = erts_bin,
        erts_bin_short_path = erts_bin_short_path,
        exec_erts_bin = "",
        exec_erts_bin_short_path = "",
        fips = ctx.attr.fips,
        fully_static = ctx.attr.fully_static,
        jit = ctx.attr.jit,
        runtime_wrapped = ctx.attr.runtime_wrapped,
    )
    activation = prepare_crypto_runtime(ctx, otp_contract, ctx.label.name + "_crypto_state", activate = otp_contract.fips == "required")
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
    jit_checks = [] if ctx.attr.jit == "auto" else [
        ",",
        "emu" if ctx.attr.jit == "disabled" else "jit",
        "=erlang:system_info(emu_flavor)",
    ]
    runtime_assertion = "assert_static_executables" if ctx.attr.fully_static else "assert_wrapped_executables"
    declared_elf_roots = [crypto.sysroot.path] if crypto else []
    expression = "".join([
        "{ok,artifact_normalizer,N}=compile:file(",
        _erl_string(ctx.file._normalizer.path),
        ",[binary,report_errors,report_warnings])",
        ",{module,artifact_normalizer}=code:load_binary(artifact_normalizer,",
        _erl_string(ctx.file._normalizer.path),
        ",N)",
        ",ok=artifact_normalizer:",
        runtime_assertion,
        "(",
        _erl_string(erlang_home),
        ")",
        ",ok=artifact_normalizer:assert_declared_elf_closure(",
        _erl_string(erlang_home),
        ",",
        "[{}]".format(",".join([_erl_string(path) for path in declared_elf_roots])),
        ")",
        ",",
        "E=",
        _erl_string(ctx.attr.version),
        ",{ok,B}=file:read_file(",
        _erl_string(ctx.file.version_marker.path),
        ")",
        ",E=string:trim(binary_to_list(B))",
        ",M=hd(string:tokens(E,\".\"))",
        ",M=erlang:system_info(otp_release)",
    ] + jit_checks + crypto_checks + [
        ",ok=file:write_file(",
        _erl_string(version_file.path),
        ",[E,10])",
        ",case file:del_dir_r(",
        _erl_string(state),
        ") of ok->ok;{error,enoent}->ok end",
        ",halt().",
    ])
    args = ctx.actions.args()
    args.add_all(["-noshell", "-eval", expression])
    environment = otp_runtime_env(otp_contract)
    environment.update(activation.environment)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(
            otp_runtime_erl_args(otp_contract) +
            fips_erl_args(otp_contract, activate = otp_contract.fips == "required"),
        ),
        "HOME": state + "/home",
        "LANG": "C",
        "LC_ALL": "C",
        "RULES_ELIXIR_MIX_CRYPTO_STATE": state,
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = execution_erlexec_file(otp_contract),
        arguments = [args],
        inputs = depset(
            direct = ctx.files.srcs + [ctx.file._normalizer] + ([crypto.sysroot] if crypto else []),
            transitive = [activation.files, crypto_runtime_files(otp_contract)],
        ),
        outputs = [version_file],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "OTPVERIFY",
        use_default_shell_env = False,
    )
    runtime_files = depset(
        direct = ctx.files.srcs + [version_file],
        transitive = [crypto.exec_files] if crypto else [],
    )

    return [
        DefaultInfo(files = runtime_files),
        OtpInfo(
            version = ctx.attr.version,
            boot_file = ctx.file.boot_file,
            boot_file_short_path = ctx.file.boot_file.short_path if ctx.file.boot_file else "",
            crypto_sdk = crypto,
            erlang_home = erlang_home,
            erlang_home_short_path = erlang_home_short_path,
            erl = ctx.file.erlexec,
            erlexec = ctx.file.erlexec,
            erts_bin = erts_bin,
            erts_bin_short_path = erts_bin_short_path,
            exec_erts_bin = "",
            exec_erts_bin_short_path = "",
            fips = ctx.attr.fips,
            fully_static = ctx.attr.fully_static,
            jit = ctx.attr.jit,
            runtime_wrapped = ctx.attr.runtime_wrapped,
            runtime_files = runtime_files,
            static_crypto_nif = ctx.attr.static_crypto_nif,
            version_file = version_file,
        ),
    ]

_otp_prebuilt_release = rule(
    implementation = _otp_prebuilt_release_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "boot_file": attr.label(
            allow_single_file = [".boot"],
            doc = "Optional pre-install boot file; passed extensionless with -boot.",
        ),
        "crypto_sdk": attr.label(allow_files = True),
        "fips": attr.string(default = "disabled", values = ["disabled", "required"]),
        "fully_static": attr.bool(
            default = False,
            doc = "Require every native OTP executable to be statically linked and verify that closure.",
        ),
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
        "jit": attr.string(default = "auto", values = ["auto", "disabled", "required"]),
        "runtime_wrapped": attr.bool(
            default = False,
            doc = "Require every dynamic native executable to have an adjacent declared static SDK wrapper.",
        ),
        "version_marker": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Installed releases/<major>/OTP_VERSION file.",
        ),
        "static_crypto_nif": attr.bool(default = False),
        "_normalizer": attr.label(
            default = Label("//private:artifact_normalizer.erl"),
            allow_single_file = [".erl"],
        ),
    },
)

def otp_prebuilt_release(name, exec_compatible_with, **kwargs):
    """Exposes a prebuilt OTP runtime with an explicit execution ABI.

    Args:
      name: Target name.
      exec_compatible_with: Linux OS and exactly one supported execution CPU.
      **kwargs: Remaining `_otp_prebuilt_release` attributes and common rule attributes.
    """
    constraints = [str(value) for value in exec_compatible_with]
    cpus = [
        value
        for value in constraints
        if value.endswith("//cpu:x86_64") or value.endswith("//cpu:arm64")
    ]
    if len(cpus) != 1 or not any([value.endswith("//os:linux") for value in constraints]):
        fail(
            (
                "otp_prebuilt_release '{}' exec_compatible_with must name Linux and exactly one of " +
                "@platforms//cpu:x86_64 or @platforms//cpu:arm64"
            ).format(name),
        )
    _otp_prebuilt_release(
        name = name,
        exec_compatible_with = exec_compatible_with,
        **kwargs
    )
