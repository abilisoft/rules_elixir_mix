"""Declared C/C++ toolchain used only to analyze native-rule plumbing."""

load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "tool_path")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

def _analysis_cc_toolchain_config_impl(ctx):
    tool = "/proc/self/cwd/" + ctx.executable.tool.path
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        abi_libc_version = "analysis-only",
        abi_version = "analysis-only",
        compiler = "analysis-only",
        host_system_name = "analysis-only",
        target_cpu = ctx.attr.cpu,
        target_libc = "analysis-only",
        target_system_name = "analysis-only",
        tool_paths = [
            tool_path(name = name, path = tool)
            for name in [
                "ar",
                "cpp",
                "gcc",
                "gcov",
                "ld",
                "nm",
                "objdump",
                "strip",
            ]
        ],
        toolchain_identifier = "rules-elixir-mix-analysis-{}".format(ctx.attr.cpu),
    )

analysis_cc_toolchain_config = rule(
    implementation = _analysis_cc_toolchain_config_impl,
    attrs = {
        "cpu": attr.string(mandatory = True),
        "tool": attr.label(
            executable = True,
            mandatory = True,
            cfg = "exec",
        ),
    },
    provides = [CcToolchainConfigInfo],
)
