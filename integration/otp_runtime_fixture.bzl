"""Test-only OTP provider used to exercise runtime ABI failures."""

load("@rules_elixir_mix//private:beam_info.bzl", "OtpInfo")

def _unverified_otp_runtime_fixture_impl(ctx):
    source_paths = {file.path: True for file in ctx.files.srcs}
    required = [ctx.file.erlexec, ctx.file.version_marker]
    if ctx.file.boot_file:
        required.append(ctx.file.boot_file)
    for file in required:
        if file.path not in source_paths:
            fail("unverified_otp_runtime_fixture inputs must be included in srcs: {}".format(file.path))

    erlang_home = ctx.file.erlexec.path.rsplit("/", 3)[0]
    erlang_home_short_path = ctx.file.erlexec.short_path.rsplit("/", 3)[0]
    erts_bin = ctx.file.erlexec.dirname
    erts_bin_short_path = ctx.file.erlexec.short_path.rsplit("/", 1)[0]
    runtime_files = depset(ctx.files.srcs)
    return [
        DefaultInfo(files = runtime_files),
        OtpInfo(
            version = ctx.attr.version,
            boot_file = ctx.file.boot_file,
            boot_file_short_path = ctx.file.boot_file.short_path if ctx.file.boot_file else "",
            crypto_sdk = None,
            erlang_home = erlang_home,
            erlang_home_short_path = erlang_home_short_path,
            erl = ctx.file.erlexec,
            erlexec = ctx.file.erlexec,
            erts_bin = erts_bin,
            erts_bin_short_path = erts_bin_short_path,
            exec_erts_bin = "",
            exec_erts_bin_short_path = "",
            fips = "disabled",
            fully_static = True,
            jit = "auto",
            runtime_wrapped = False,
            runtime_files = runtime_files,
            static_crypto_nif = False,
            version_file = ctx.file.version_marker,
        ),
    ]

unverified_otp_runtime_fixture = rule(
    implementation = _unverified_otp_runtime_fixture_impl,
    attrs = {
        "boot_file": attr.label(allow_single_file = [".boot"]),
        "erlexec": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "version": attr.string(mandatory = True),
        "version_marker": attr.label(allow_single_file = True, mandatory = True),
    },
    doc = "Exposes a declared runtime without verification so a smoke test can prove an expected ABI rejection.",
)
