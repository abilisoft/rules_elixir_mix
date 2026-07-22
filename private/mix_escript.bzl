"""Hermetic, cacheable Mix escript output rule."""

load("//private:beam_info.bzl", "ErlangAppInfo", "crypto_runtime_files", "erl_env_flags", "execution_erts_bin", "execution_root_path", "flat_compile_deps", "flat_deps", "otp_runtime_env", "otp_runtime_erl_args", "path_join")
load("//private:mix_execution.bzl", "run_mix_action")
load("//private:mix_info.bzl", "MixProjectInfo")

MixEscriptInfo = provider(
    doc = "A Mix-built escript and the declared runtime needed to execute it.",
    fields = {
        "escript": "Executable escript artifact.",
        "runtime_environment": "Opaque runtime environment recorded beside a provider-backed escript.",
    },
)

def _validate_output_name(value):
    if not value or value.startswith("/") or "\\" in value:
        fail("mix_escript output_name must be a non-empty package-relative POSIX path")
    if any([part in ["", ".", ".."] for part in value.split("/")]):
        fail("mix_escript output_name must be normalized: '{}'".format(value))

def _runfiles_relative_path(ctx, short_path):
    if short_path.startswith("../"):
        return short_path.removeprefix("../")
    return path_join(ctx.workspace_name, short_path)

def _runfiles_artifact_path(ctx, output, short_path):
    return path_join(
        output.path + ".runfiles",
        _runfiles_relative_path(ctx, short_path),
    )

def _escript_program_path(otp, runfiles = False):
    executable = ".real-escript" if (
        getattr(otp, "runtime_wrapped", False) or
        getattr(otp, "exec_erts_bin", "")
    ) else "escript"
    return path_join(execution_erts_bin(otp, runfiles = runfiles), executable)

def _escript_program(ctx, otp, output):
    return _runfiles_artifact_path(
        ctx,
        output,
        _escript_program_path(otp, runfiles = True),
    )

def _wrapper_environment(otp, program, payload):
    sdk = otp.crypto_sdk
    if not sdk or not sdk.execution_exec_wrapper:
        return {}
    sysroot = execution_root_path(sdk.sysroot.path)
    activation_root = execution_root_path(sdk.prepared_state.path)
    environment = {
        key: value.replace("{sysroot}", sysroot).replace("{activation_root}", activation_root)
        for key, value in sdk.runtime_environment.items()
    }
    environment.update(otp_runtime_env(otp))
    environment.update({
        key: value.replace("{sysroot}", sysroot).replace("{program}", execution_root_path(program))
        for key, value in sdk.execution_wrapper_environment.items()
    })
    environment.update({
        "ERL_AFLAGS": erl_env_flags(otp_runtime_erl_args(otp) + ["+fnu"]),
        "PROGNAME": "escript",
        "RULES_FIPS_RUNTIME_FIXED_ARG_0": execution_root_path(payload.path),
        "RULES_FIPS_RUNTIME_FIXED_ARG_COUNT": "1",
    })
    return environment

def _boot_args(ctx, otp, output):
    if not otp.boot_file:
        return []
    boot = _runfiles_artifact_path(ctx, output, otp.boot_file_short_path)
    return ["-boot", boot.removesuffix(".boot")]

def _environment_file_content(environment):
    for key, value in environment.items():
        if "\n" in key or "=" in key or "\n" in value:
            fail("escript wrapper environment cannot encode '{}'".format(key))
    return "".join([
        "{}={}\n".format(key, environment[key])
        for key in sorted(environment.keys())
    ])

def _mix_escript_impl(ctx):
    project = ctx.attr.lib[MixProjectInfo]
    if project.mix_env != ctx.attr.mix_env:
        fail("mix_escript mix_env '{}' does not match {} compiled with '{}'".format(
            ctx.attr.mix_env,
            ctx.attr.lib.label,
            project.mix_env,
        ))
    output_name = ctx.attr.output_name or ctx.label.name
    _validate_output_name(output_name)

    toolchain = ctx.toolchains["//:toolchain_type"]
    otp = toolchain.otpinfo
    sdk = otp.crypto_sdk
    if sdk and not sdk.fully_static and not sdk.execution_exec_wrapper:
        fail("mix_escript requires a non-static crypto SDK to provide its shell-free execution wrapper")

    wrapped = bool(sdk and sdk.execution_exec_wrapper)
    output = ctx.actions.declare_file(output_name)
    escript = ctx.actions.declare_file(output_name + ".escript") if wrapped else output
    build_root = escript.path + ".build"
    dependencies = flat_deps([ctx.attr.lib])
    action_dependencies = flat_compile_deps([ctx.attr.lib])
    dependency_apps = [
        target[ErlangAppInfo].app_name
        for target in dependencies
        if target.label != ctx.attr.lib.label
    ]
    dependency_manifest = ctx.actions.declare_file(ctx.label.name + "_escript_deps_manifest")
    ctx.actions.write(
        dependency_manifest,
        "[{}].\n".format(", ".join(['"{}"'.format(app) for app in dependency_apps])),
    )
    project_files = project.project_files.to_list()
    escript_program = _escript_program(ctx, otp, output)
    if getattr(otp, "runtime_wrapped", False):
        interpreter = _runfiles_artifact_path(
            ctx,
            output,
            path_join(execution_erts_bin(otp, runfiles = True), "escript"),
        )
    elif sdk and sdk.execution_exec_wrapper:
        interpreter = _runfiles_artifact_path(
            ctx,
            output,
            sdk.execution_exec_wrapper.executable.short_path,
        )
    else:
        interpreter = escript_program
    shebang = "#!/rules_elixir_mix/escript\n" if wrapped else "#!{}\n".format(interpreter)
    if len(shebang) > 255:
        fail("mix_escript interpreter path exceeds Linux's 255-byte shebang limit; shorten the package or target name")
    emu_args = erl_env_flags(["+fnu"] + _boot_args(ctx, otp, output))
    internal_env = {
        "RULES_ELIXIR_MIX_BAZEL_DEPS": "true",
        "RULES_ELIXIR_MIX_ESCRIPT_DEPS_MANIFEST": dependency_manifest.path,
        "RULES_ELIXIR_MIX_ESCRIPT_OUTPUT": escript.path,
        "RULES_ELIXIR_MIX_ESCRIPT_SHEBANG": shebang,
        "RULES_ELIXIR_MIX_PRELOAD_DEPS": "true",
        "RULES_ELIXIR_MIX_PREPARE_COMPILED_PROJECT": "true",
        "RULES_ELIXIR_MIX_REMOVE_BUILD_ROOT": "true",
    }
    if emu_args:
        internal_env["RULES_ELIXIR_MIX_ESCRIPT_EMU_ARGS"] = emu_args

    run_mix_action(
        ctx = ctx,
        task = "escript.build",
        task_args = [
            "--no-archives-check",
            "--no-compile",
            "--no-deps-check",
            "--no-prune-code-paths",
        ],
        mix_config = project.mix_config,
        mix_env = ctx.attr.mix_env,
        build_root = build_root,
        deps = action_dependencies,
        inputs = project_files + ctx.files.data + [dependency_manifest],
        project_inputs = project_files,
        project_entries = project.project_entries,
        outputs = [escript],
        internal_env = internal_env,
        user_env = {
            key: ctx.expand_location(value, ctx.attr.data)
            for key, value in ctx.attr.env.items()
        },
        mnemonic = "MIXESCRIPT",
    )

    if wrapped:
        ctx.actions.symlink(
            output = output,
            target_file = sdk.execution_exec_wrapper.executable,
            is_executable = True,
        )
    wrapper_environment = _wrapper_environment(otp, _escript_program_path(otp), escript)
    runtime_environment = None
    runtime_direct = []
    if wrapper_environment:
        runtime_environment = ctx.actions.declare_file(output_name + ".runtime.env")
        ctx.actions.write(runtime_environment, _environment_file_content(wrapper_environment))
        runtime_direct.append(runtime_environment)

    prepared_state = [sdk.prepared_state] if sdk and sdk.prepared_state else []
    runtime_files = depset(
        direct = runtime_direct + prepared_state,
        transitive = [toolchain.runtime_files, crypto_runtime_files(otp)],
    )
    default_files = [output, escript] + runtime_direct
    runfiles = ctx.runfiles(
        files = [output, escript] + runtime_direct,
        transitive_files = runtime_files,
    )
    return [
        DefaultInfo(
            executable = output,
            files = depset(default_files),
            runfiles = runfiles,
        ),
        MixEscriptInfo(
            escript = escript,
            runtime_environment = runtime_environment,
        ),
    ]

mix_escript = rule(
    implementation = _mix_escript_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
        "lib": attr.label(mandatory = True, providers = [ErlangAppInfo, MixProjectInfo]),
        "mix_env": attr.string(default = "prod", values = ["dev", "prod", "test"]),
        "output_name": attr.string(doc = "Optional package-relative executable name; defaults to the target name."),
    },
    doc = "Build a declared Mix project as an offline escript executable tool.",
    executable = True,
    toolchains = ["//:toolchain_type"],
)
