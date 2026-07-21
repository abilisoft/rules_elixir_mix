"""Runtime and ELF linkage test for FIPS-required OTP toolchains."""

load("//private:beam_info.bzl", "crypto_runtime_files", "erl_env_flags", "fips_erl_args", "otp_runtime_env", "otp_runtime_erl_args", "prepare_crypto_runtime", "test_erl_launcher")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[S|R]=A,C=compile:file(S,[binary,report_errors,report_warnings]),M=element(2,C),B=element(3,C),{module,M}=code:load_binary(M,S,B),M:main(R),halt()."

def _elixir_fips_runtime_test_impl(ctx):
    toolchain = ctx.toolchains["//:otp_toolchain_type"]
    otp = toolchain.otpinfo
    if otp.fips != "required":
        fail("elixir_fips_runtime_test requires a toolchain with fips='required'")
    if not otp.static_crypto_nif:
        fail("elixir_fips_runtime_test requires static_crypto_nif=True")

    activation = prepare_crypto_runtime(
        ctx,
        otp,
        ctx.label.name + "_crypto_state",
        runfiles = True,
    )
    args = otp_runtime_erl_args(otp, runfiles = True) + [
        "-noshell",
    ] + fips_erl_args(otp, runfiles = True, activate = False) + [
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._driver.short_path,
        otp.erlang_home_short_path,
    ]
    runfiles = ctx.runfiles(
        files = [ctx.file._driver],
        transitive_files = depset(transitive = [
            toolchain.runtime_files,
            crypto_runtime_files(otp),
            activation.files,
        ]),
    )
    environment = otp_runtime_env(otp, runfiles = True)
    environment.update(activation.environment)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
    })
    return [
        DefaultInfo(executable = test_erl_launcher(ctx, otp), runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
    ]

elixir_fips_runtime_test = rule(
    implementation = _elixir_fips_runtime_test_impl,
    attrs = {
        "_driver": attr.label(
            default = Label("//private:fips_runtime_test.erl"),
            allow_single_file = [".erl"],
        ),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)
