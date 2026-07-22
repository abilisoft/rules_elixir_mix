"""Focused ABI smoke test for a declared OTP runtime."""

load(
    "//private:beam_info.bzl",
    "OtpInfo",
    "crypto_runtime_files",
    "erl_env_flags",
    "execution_erlexec_file",
    "fips_erl_args",
    "otp_runtime_env",
    "otp_runtime_erl_args",
    "prepare_crypto_runtime",
)

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _otp_runtime_smoke_test_impl(ctx):
    otp = ctx.attr.otp[OtpInfo]
    activation = prepare_crypto_runtime(
        ctx,
        otp,
        ctx.label.name + "_crypto_state",
        runfiles = True,
        activate = otp.fips == "required",
    )
    expected_release = otp.version.split(".")[0]
    jit_check = [] if otp.jit == "auto" else [
        ",",
        "emu" if otp.jit == "disabled" else "jit",
        "=erlang:system_info(emu_flavor)",
    ]
    expression = "".join([
        "E=",
        _erl_string(expected_release),
        ",E=erlang:system_info(otp_release)",
    ] + jit_check + [
        ",io:format(\"OTP bootstrap ABI smoke passed: OTP ~ts~n\",[E])",
        ",halt(0).",
    ])
    environment = otp_runtime_env(otp, runfiles = True)
    environment.update(activation.environment)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(
            otp_runtime_erl_args(otp, runfiles = True) +
            fips_erl_args(otp, activate = otp.fips == "required") +
            ["-noshell", "-eval", expression],
        ),
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
    })

    executable = ctx.actions.declare_file(ctx.label.name + "_erl")
    ctx.actions.symlink(
        output = executable,
        target_file = execution_erlexec_file(otp),
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        transitive_files = depset(transitive = [
            otp.runtime_files,
            crypto_runtime_files(otp),
            activation.files,
        ]),
    )
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
        testing.ExecutionInfo({"block-network": "1"}),
    ]

otp_runtime_smoke_test = rule(
    implementation = _otp_runtime_smoke_test_impl,
    attrs = {
        "otp": attr.label(mandatory = True, providers = [OtpInfo]),
    },
    doc = "Starts a declared OTP runtime and validates its ABI-visible OTP release.",
    test = True,
)
