"""Positive Bazel test for an expected OTP runtime ABI rejection."""

load(
    "//private:beam_info.bzl",
    "OtpInfo",
    "crypto_runtime_files",
    "erl_env_flags",
    "execution_erlexec_file",
    "otp_runtime_env",
    "otp_runtime_erl_args",
    "test_erl_launcher",
)

_DRIVER_EVAL = "A=init:get_plain_arguments(),[S|R]=A,C=compile:file(S,[binary,report_errors,report_warnings]),M=element(2,C),B=element(3,C),{module,M}=code:load_binary(M,S,B),M:main(R),halt()."

def _otp_runtime_rejection_test_impl(ctx):
    runner_toolchain = ctx.toolchains["//:otp_toolchain_type"]
    runner = runner_toolchain.otpinfo
    rejected = ctx.attr.otp[OtpInfo]
    rejected_erlexec = execution_erlexec_file(rejected)
    args = otp_runtime_erl_args(runner, runfiles = True) + [
        "-noshell",
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._driver.short_path,
        rejected_erlexec.short_path,
        ctx.attr.expected_error,
    ]
    environment = otp_runtime_env(runner, runfiles = True)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
    })
    runfiles = ctx.runfiles(
        files = [ctx.file._driver, rejected_erlexec],
        transitive_files = depset(transitive = [
            runner_toolchain.runtime_files,
            rejected.runtime_files,
            crypto_runtime_files(runner),
            crypto_runtime_files(rejected),
        ]),
    )
    return [
        DefaultInfo(executable = test_erl_launcher(ctx, runner), runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
        testing.ExecutionInfo({"block-network": "1"}),
    ]

otp_runtime_rejection_test = rule(
    implementation = _otp_runtime_rejection_test_impl,
    attrs = {
        "expected_error": attr.string(mandatory = True),
        "otp": attr.label(mandatory = True, providers = [OtpInfo]),
        "_driver": attr.label(
            default = Label("//private:otp_runtime_rejection_test.erl"),
            allow_single_file = [".erl"],
        ),
    },
    doc = "Passes only when a declared OTP runtime is rejected with the expected execution error.",
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)
