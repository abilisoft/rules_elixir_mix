"""Shell-free rule for running analysis-oriented Mix tasks as Bazel tests."""

load("//private:beam_info.bzl", "ErlangAppInfo")
load("//private:mix_execution.bzl", "mix_test_result", "runfile_path_from_project")
load("//private:mix_info.bzl", "MixProjectInfo")

def _version_tuple(value):
    parts = value.split("-", 1)[0].split(".")
    if len(parts) < 2:
        fail("invalid Elixir version '{}' in toolchain".format(value))
    return [int(part) for part in parts] + [0] * (3 - len(parts))

def _mix_task_test_impl(ctx):
    if ctx.attr.minimum_elixir_version:
        actual = ctx.toolchains["//:toolchain_type"].elixirinfo.version
        if _version_tuple(actual) < _version_tuple(ctx.attr.minimum_elixir_version):
            fail("{} requires Elixir {} or newer; selected toolchain is {}".format(
                ctx.label,
                ctx.attr.minimum_elixir_version,
                actual,
            ))
    task_args = list(ctx.attr.task_args)
    if ctx.attr.task == "format":
        project = ctx.attr.lib[MixProjectInfo]
        task_args.extend([
            runfile_path_from_project(project, file)
            for file in ctx.files.srcs
        ])
    return mix_test_result(
        ctx = ctx,
        task = ctx.attr.task,
        task_args = task_args,
        srcs = ctx.files.srcs,
        data = ctx.attr.data,
        tools = ctx.attr.tools,
    )

mix_task_test = rule(
    implementation = _mix_task_test_impl,
    attrs = {
        "lib": attr.label(mandatory = True, providers = [ErlangAppInfo, MixProjectInfo]),
        "minimum_elixir_version": attr.string(),
        "task": attr.string(mandatory = True),
        "task_args": attr.string_list(),
        "srcs": attr.label_list(allow_files = True),
        "config": attr.label_list(allow_files = [".ex", ".exs"]),
        "coverage_output": attr.string(),
        "data": attr.label_list(allow_files = True),
        "tools": attr.label_list(cfg = "exec", allow_files = True),
        "env": attr.string_dict(),
    },
    toolchains = ["//:toolchain_type"],
    test = True,
)
