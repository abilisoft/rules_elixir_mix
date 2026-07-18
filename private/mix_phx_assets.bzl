"""Cacheable Phoenix static-asset digest assembly."""

load("//private:beam_info.bzl", "ErlangAppInfo", "flat_deps")
load("//private:elixir_priv.bzl", "ElixirPrivInfo")
load("//private:elixir_source.bzl", "ElixirSourceInfo")
load("//private:mix_execution.bzl", "run_mix_action")
load("//private:mix_info.bzl", "MixProjectInfo")

_OUTPUT_ARGUMENT = "__RULES_ELIXIR_MIX_OUTPUT__"

def _mix_phx_assets_impl(ctx):
    project = ctx.attr.lib[MixProjectInfo]
    if project.mix_env != ctx.attr.mix_env:
        fail("mix_phx_assets mix_env '{}' does not match {} compiled with '{}'".format(
            ctx.attr.mix_env,
            ctx.attr.lib.label,
            project.mix_env,
        ))
    output = ctx.actions.declare_directory(ctx.label.name + "_static")
    build_root = output.path + ".build"
    dependencies = flat_deps([ctx.attr.lib])
    generated_entries = [
        entry
        for target in ctx.attr.generated_srcs
        for entry in target[ElixirSourceInfo].entries
    ]
    generated_files = [entry.source for entry in generated_entries]
    project_files = project.project_files.to_list() + ctx.files.srcs + generated_files
    run_mix_action(
        ctx = ctx,
        task = "phx.digest",
        task_args = [
            ctx.attr.static_path,
            "--output",
            _OUTPUT_ARGUMENT,
            "--no-compile",
        ] + ctx.attr.phx_digest_opts,
        mix_config = project.mix_config,
        mix_env = ctx.attr.mix_env,
        build_root = build_root,
        deps = dependencies,
        inputs = project_files,
        project_inputs = project_files,
        project_entries = project.project_entries + generated_entries,
        outputs = [output],
        internal_env = {
            "RULES_ELIXIR_MIX_BAZEL_DEPS": "true",
            "RULES_ELIXIR_MIX_OUTPUT": output.path,
            "RULES_ELIXIR_MIX_PRELOAD_DEPS": "true",
            "RULES_ELIXIR_MIX_REMOVE_BUILD_ROOT": "true",
        },
        mnemonic = "PHXDIGEST",
    )
    return [
        DefaultInfo(files = depset([output]), runfiles = ctx.runfiles(files = [output])),
        ElixirPrivInfo(entries = [struct(
            destination = "static",
            source = output,
        )]),
    ]

mix_phx_assets = rule(
    implementation = _mix_phx_assets_impl,
    attrs = {
        "lib": attr.label(mandatory = True, providers = [ErlangAppInfo, MixProjectInfo]),
        "generated_srcs": attr.label_list(providers = [ElixirSourceInfo]),
        "srcs": attr.label_list(allow_files = True),
        "mix_env": attr.string(default = "prod", values = ["dev", "prod", "test"]),
        "phx_digest_opts": attr.string_list(),
        "static_path": attr.string(default = "priv/static"),
    },
    toolchains = ["//:toolchain_type"],
)
