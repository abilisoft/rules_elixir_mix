"""Runtime and ELF linkage test for FIPS-required OTP toolchains."""

load("//private:beam_info.bzl", "crypto_runtime_files", "erl_env_flags", "fips_erl_args", "otp_runtime_env", "runtime_path_erl_args", "test_erl_launcher")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[S|R]=A,C=compile:file(S,[binary,report_errors,report_warnings]),M=element(2,C),B=element(3,C),{module,M}=code:load_binary(M,S,B),M:main(R),halt()."

def _elixir_fips_runtime_test_impl(ctx):
    toolchain = ctx.toolchains["//:otp_toolchain_type"]
    otp = toolchain.otpinfo
    if otp.fips != "required":
        fail("elixir_fips_runtime_test requires a toolchain with fips='required'")
    if not otp.static_crypto_nif:
        fail("elixir_fips_runtime_test requires static_crypto_nif=True")

    inspector = ctx.executable.elf_inspector
    args = runtime_path_erl_args() + [
        "-noshell",
    ] + fips_erl_args(otp, runfiles = True) + [
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._driver.short_path,
        otp.erlang_home_short_path,
        inspector.short_path,
    ]
    runfiles = ctx.runfiles(
        files = [ctx.file._driver, inspector],
        transitive_files = depset(transitive = [
            toolchain.runtime_files,
            crypto_runtime_files(otp),
        ]),
    ).merge(ctx.attr.elf_inspector[DefaultInfo].default_runfiles)
    environment = otp_runtime_env(otp, runfiles = True)
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
        "elf_inspector": attr.label(mandatory = True, executable = True, cfg = "target", allow_files = True),
        "_driver": attr.label(
            default = Label("//private:fips_runtime_test.erl"),
            allow_single_file = [".erl"],
        ),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)
