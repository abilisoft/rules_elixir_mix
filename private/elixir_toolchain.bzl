"""Elixir toolchain definition and access helpers."""

load("//private:beam_info.bzl", "OtpInfo")
load("//private:elixir_info.bzl", "ElixirInfo")

def _native_build_tools(ctx):
    configured = [
        bool(ctx.attr.native_bash),
        bool(ctx.attr.native_make),
        bool(ctx.attr.native_perl),
        bool(ctx.attr.native_posix_tools),
    ]
    if not any(configured):
        return None
    if not all(configured):
        fail("native Bash, Make, Perl, and POSIX tools must be declared together")

    targets = [ctx.attr.native_bash, ctx.attr.native_make, ctx.attr.native_perl] + ctx.attr.native_posix_tools
    return struct(
        bash = ctx.attr.native_bash[DefaultInfo].files_to_run,
        files = depset(transitive = [target[DefaultInfo].files for target in targets]),
        make = ctx.attr.native_make[DefaultInfo].files_to_run,
        path_files = depset(transitive = [target[DefaultInfo].files for target in ctx.attr.native_posix_tools]),
        perl = ctx.attr.native_perl[DefaultInfo].files_to_run,
        tools = [
            ctx.attr.native_bash[DefaultInfo].files_to_run,
            ctx.attr.native_make[DefaultInfo].files_to_run,
            ctx.attr.native_perl[DefaultInfo].files_to_run,
        ],
    )

def _elixir_toolchain_impl(ctx):
    otp_info = ctx.attr.elixir[OtpInfo]
    elixir_info = ctx.attr.elixir[ElixirInfo]
    return [platform_common.ToolchainInfo(
        otpinfo = otp_info,
        elixirinfo = elixir_info,
        native_build_tools = _native_build_tools(ctx),
        runtime_files = depset(transitive = [
            otp_info.runtime_files,
            elixir_info.runtime_files,
        ]),
    )]

elixir_toolchain = rule(
    implementation = _elixir_toolchain_impl,
    attrs = {
        "elixir": attr.label(
            mandatory = True,
            providers = [OtpInfo, ElixirInfo],
        ),
        "native_bash": attr.label(executable = True, allow_files = True, cfg = "exec"),
        "native_make": attr.label(executable = True, allow_files = True, cfg = "exec"),
        "native_perl": attr.label(executable = True, allow_files = True, cfg = "exec"),
        "native_posix_tools": attr.label_list(allow_files = True, cfg = "exec"),
    },
)
