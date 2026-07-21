"""Shell-free boot test for a Mix release artifact."""

load("//private:beam_info.bzl", "crypto_runtime_files", "erl_env_flags", "fips_erl_args", "otp_runtime_env", "otp_runtime_erl_args", "prepare_crypto_runtime", "test_erl_launcher")
load("//private:release_info.bzl", "ReleaseInfo")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[S|R]=A,C=compile:file(S,[binary,report_errors,report_warnings]),M=element(2,C),B=element(3,C),{module,M}=code:load_binary(M,S,B),M:main(R),halt()."

def _validate_required_path(path):
    if not path or path.startswith("/") or "\\" in path:
        fail("elixir_release_test required_paths must contain normalized release-relative paths")
    if any([part in ["", ".", ".."] for part in path.split("/")]):
        fail("elixir_release_test required path '{}' is not normalized".format(path))

def _elixir_release_test_impl(ctx):
    toolchain = ctx.toolchains["//:otp_toolchain_type"]
    otp = toolchain.otpinfo
    activation = prepare_crypto_runtime(
        ctx,
        otp,
        ctx.label.name + "_crypto_state",
        runfiles = True,
    )
    release = ctx.attr.release[ReleaseInfo]
    release_files = ctx.attr.release[DefaultInfo].files.to_list()
    if len(release_files) != 1 or not release_files[0].is_directory:
        fail("elixir_release_test requires exactly one release tree artifact")
    release_root = release_files[0]
    for path in ctx.attr.required_paths:
        _validate_required_path(path)
    for path in ctx.attr.required_file_contents:
        _validate_required_path(path)
    crypto_environment_keys = sorted(
        otp.crypto_sdk.runtime_environment.keys() + otp.crypto_sdk.execution_wrapper_environment.keys(),
    ) if otp.crypto_sdk else []
    required_file_contents = sorted(ctx.attr.required_file_contents.items())
    args = otp_runtime_erl_args(otp, runfiles = True) + [
        "-noshell",
    ] + fips_erl_args(otp, runfiles = True, activate = False) + [
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._driver.short_path,
        release_root.short_path,
        release.name,
        release.app_name,
        "true" if release.crypto_activation else "false",
        "true" if release.fips == "required" else "false",
        str(len(crypto_environment_keys)),
        str(len(ctx.attr.required_paths)),
        str(len(required_file_contents)),
        str(len(ctx.attr.consolidated_protocols)),
    ] + crypto_environment_keys + ctx.attr.required_paths + [
        value
        for pair in required_file_contents
        for value in pair
    ] + ctx.attr.consolidated_protocols
    runfiles = ctx.runfiles(
        files = [ctx.file._driver, release_root],
        transitive_files = depset(transitive = [
            toolchain.runtime_files,
            crypto_runtime_files(otp),
            activation.files,
        ]),
    ).merge(ctx.attr.release[DefaultInfo].default_runfiles)
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

elixir_release_test = rule(
    implementation = _elixir_release_test_impl,
    attrs = {
        "release": attr.label(mandatory = True, providers = [ReleaseInfo]),
        "consolidated_protocols": attr.string_list(),
        "required_file_contents": attr.string_dict(),
        "required_paths": attr.string_list(),
        "_driver": attr.label(
            default = Label("//private:release_runtime_test.erl"),
            allow_single_file = [".erl"],
        ),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)
