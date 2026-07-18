"""Shell-free ExUnit test rule backed by Mix."""

load("//private:beam_info.bzl", "ErlangAppInfo")
load("//private:mix_execution.bzl", "mix_test_result", "runfile_path_from_project")
load("//private:mix_info.bzl", "MixProjectInfo")

def _mix_test_impl(ctx):
    mix_info = ctx.attr.lib[MixProjectInfo]
    if mix_info.mix_env != "test":
        fail("mix_test requires lib compiled with mix_env='test', got '{}'".format(mix_info.mix_env))

    args = []
    if ctx.attr.warnings_as_errors:
        args.append("--warnings-as-errors")
    args.extend(["--no-compile", "--no-deps-check"])
    if ctx.attr.no_start:
        args.append("--no-start")
    args.extend([
        runfile_path_from_project(mix_info, file)
        for file in ctx.files.srcs
        if file.basename.endswith("_test.exs")
    ])
    args.extend(ctx.attr.mix_test_opts)

    return mix_test_result(
        ctx = ctx,
        task = "test",
        task_args = args,
        srcs = ctx.files.srcs,
        data = ctx.attr.data,
        tools = ctx.attr.tools,
    )

mix_test = rule(
    implementation = _mix_test_impl,
    attrs = {
        "lib": attr.label(mandatory = True, providers = [ErlangAppInfo, MixProjectInfo]),
        "srcs": attr.label_list(allow_files = [".exs"]),
        "data": attr.label_list(allow_files = True),
        "config": attr.label_list(allow_files = [".ex", ".exs"]),
        "tools": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
        "no_start": attr.bool(default = False),
        "mix_test_opts": attr.string_list(),
        "createdb": attr.label(executable = True, cfg = "target", allow_files = True),
        "initdb": attr.label(executable = True, cfg = "target", allow_files = True),
        "postgres": attr.label(executable = True, cfg = "target", allow_files = True),
        "postgres_database": attr.string(default = "rules_elixir_mix_test"),
        "recompile_for_coverage": attr.bool(default = False),
        "warnings_as_errors": attr.bool(default = True),
    },
    toolchains = ["//:toolchain_type"],
    test = True,
)
