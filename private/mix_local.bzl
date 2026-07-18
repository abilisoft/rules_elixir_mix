"""Explicit local-only Mix workflows for servers, reloaders, and generators."""

load("//private:beam_info.bzl", "ErlangAppInfo", "crypto_exec_inputs", "crypto_exec_tools", "crypto_runtime_files", "erl_env_flags", "fips_erl_args", "otp_runtime_env", "path_join", "runtime_path_erl_args", "test_erl_launcher")
load("//private:mix_execution.bzl", "MIX_EVAL", "validate_user_env")
load("//private:mix_info.bzl", "MixProjectInfo")

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _local_state_name(ctx):
    value = str(ctx.label).replace("@", "").replace("//", "").replace(":", "/")
    return value[1:] if value.startswith("/") else value

def _local_bootstrap_expression(ctx, manifest):
    state_name = _local_state_name(ctx)
    statements = [
        'W=os:getenv("BUILD_WORKSPACE_DIRECTORY")',
        "true=is_list(W)",
        'S=filename:join([W,".bazel","elixir_mix",{}])'.format(_erl_string(state_name)),
        'true=os:putenv("RULES_ELIXIR_MIX_LOCAL_STATE",S)',
        'true=os:putenv("RULES_ELIXIR_MIX_CRYPTO_STATE",filename:join(S,"crypto"))',
        'true=os:putenv("RULES_ELIXIR_MIX_LOCAL_STAGE_MANIFEST",filename:absname({}))'.format(_erl_string(manifest.short_path)),
    ]
    return "begin " + ",".join(statements + ["ok"]) + " end."

def _local_stage_manifest(ctx, app, dependencies, project_root):
    if not app.project_fingerprint:
        fail("local workflow application must expose a source-project fingerprint")

    dependency_terms = []
    seen = {}
    for target in dependencies:
        info = target[ErlangAppInfo]
        if info.app_name in seen:
            continue
        seen[info.app_name] = True
        project_fingerprint = "none"
        project_entries = []
        if info.project_files:
            if not info.project_fingerprint:
                fail("dependency {} exposes project files without a source-project fingerprint".format(target.label))
            project_fingerprint = _erl_string(info.project_fingerprint.short_path)
            seen_project_destinations = {}
            for entry in info.project_entries:
                file = entry.source
                relative = entry.destination
                if relative in seen_project_destinations:
                    continue
                seen_project_destinations[relative] = True
                project_entries.append(
                    "{%s,%s}" % (_erl_string(file.short_path), _erl_string(relative)),
                )
        dependency_terms.append(
            "#{app_name=>%s,compiled_source=>%s,compile_fingerprint=>%s,project_fingerprint=>%s,project_entries=>[%s]}" % (
                _erl_string(info.app_name),
                _erl_string(path_join(info.lib_dirs_short_path[0], info.app_name)),
                _erl_string(info.compile_fingerprint.short_path),
                project_fingerprint,
                ",".join(project_entries),
            ),
        )

    project_prefix = project_root.rstrip("/") + "/" if project_root else ""
    application_project_entries = []
    for entry in app.project_entries:
        workspace_path = project_prefix + entry.destination
        if entry.source.short_path != workspace_path:
            application_project_entries.append(
                "{%s,%s}" % (_erl_string(entry.source.short_path), _erl_string(entry.destination)),
            )

    context_fingerprint = ctx.actions.declare_file(ctx.label.name + "_local_context.fingerprint")
    context_lines = [
        "schema=2",
        "mode=" + ctx.attr.mode,
        "task=" + ctx.attr.task,
        "mix_env=" + ctx.attr.mix_env,
        "otp=" + ctx.toolchains["//:toolchain_type"].otpinfo.version,
        "elixir=" + ctx.toolchains["//:toolchain_type"].elixirinfo.version,
    ] + [
        "task_arg:{}:{}".format(len(value), value)
        for value in ctx.attr.task_args
    ] + ["env:{}={}".format(key, ctx.attr.env[key]) for key in sorted(ctx.attr.env.keys())]
    ctx.actions.write(context_fingerprint, "\n".join(context_lines) + "\n")

    manifest = ctx.actions.declare_file(ctx.label.name + "_local_stage.config")
    ctx.actions.write(
        output = manifest,
        content = "#{state_name=>%s,project_root=>%s,context_fingerprint=>%s,dependencies=>[%s],application=>#{app_name=>%s,compile_fingerprint=>%s,project_fingerprint=>%s,project_entries=>[%s]}}.\n" % (
            _erl_string(_local_state_name(ctx)),
            _erl_string(project_root),
            _erl_string(context_fingerprint.short_path),
            ",".join(dependency_terms),
            _erl_string(app.app_name),
            _erl_string(app.compile_fingerprint.short_path),
            _erl_string(app.project_fingerprint.short_path),
            ",".join(application_project_entries),
        ),
    )
    return manifest, context_fingerprint, [
        entry.source
        for entry in app.project_entries
        if entry.source.short_path != project_prefix + entry.destination
    ]

def _compile_local_driver(ctx, otp):
    driver = ctx.actions.declare_file(ctx.label.name + "_local_driver/mix_local_driver.beam")
    args = ctx.actions.args()
    args.add_all([
        "-noshell",
        "+fnu",
    ] + fips_erl_args(otp) + [
        "-eval",
        "[S,O]=init:get_plain_arguments(),ok=filelib:ensure_dir(filename:join(O,\".keep\")),case compile:file(S,[deterministic,report_errors,report_warnings,{outdir,O}]) of {ok,mix_local_driver}->ok;{ok,mix_local_driver,_}->ok;Error->erlang:error({driver_compile_failed,Error}) end,halt().",
        "-extra",
        ctx.file._driver.path,
        driver.dirname,
    ])
    environment = otp_runtime_env(otp)
    environment.update({
        "HOME": driver.dirname + "/.state/home",
        "LANG": "C",
        "LC_ALL": "C",
        "RULES_ELIXIR_MIX_CRYPTO_STATE": driver.dirname + "/.state/crypto",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = otp.erlexec,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._driver],
            transitive = [otp.runtime_files, crypto_exec_inputs(otp)],
        ),
        tools = crypto_exec_tools(otp),
        outputs = [driver],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "MIXLOCALDRIVER",
        toolchain = "//:toolchain_type",
        use_default_shell_env = False,
    )
    return driver

def _local_preload_expression(mix_exs):
    statements = [
        "_='Elixir.Mix':start()",
        "_='Elixir.Code':compile_file(list_to_binary({}))".format(_erl_string(mix_exs)),
        "_='Elixir.Mix.Task':run(<<\"loadconfig\">>,[])",
        "_='Elixir.Mix.Task':run(<<\"loadpaths\">>,[<<\"--no-deps-check\">>,<<\"--no-listeners\">>])",
        'true=os:putenv("MIX_EXS",".rules_elixir_mix_project_preloaded")',
        'true=os:putenv("RULES_ELIXIR_MIX_PROJECT_PRELOADED","true")',
    ]
    return "begin " + ",".join(statements + ["ok"]) + " end."

def _mix_local_impl(ctx):
    toolchain = ctx.toolchains["//:toolchain_type"]
    project = ctx.attr.lib[MixProjectInfo]
    app = ctx.attr.lib[ErlangAppInfo]
    dependencies = app.compile_deps.to_list()
    project_root = project.mix_config.short_path.rsplit("/", 1)[0] if "/" in project.mix_config.short_path else ""
    if project_root.startswith("../"):
        fail("local workflows require a Mix project in the main workspace")
    manifest, context_fingerprint, application_project_files = _local_stage_manifest(ctx, app, dependencies, project_root)
    driver = _compile_local_driver(ctx, toolchain.otpinfo)
    driver_runfiles_dir = driver.short_path.rsplit("/", 1)[0]
    prefix = runtime_path_erl_args() + [
        "-eval",
        _local_bootstrap_expression(ctx, manifest),
        "-noshell",
        "+fnu",
    ] + fips_erl_args(toolchain.otpinfo, runfiles = True) + [
        "-pa",
        driver_runfiles_dir,
        "-eval",
        "mix_local_driver:stage(filename:absname({}))".format(_erl_string(manifest.short_path)),
        "-eval",
        _local_preload_expression(project.mix_config.basename),
        "-eval",
        "begin M=os:getenv(\"RULES_ELIXIR_MIX_LOCAL_STAGE_MANIFEST\"),true=is_list(M),'Elixir.System':at_exit(fun(_Status)->mix_local_driver:cleanup(M) end) end.",
    ]
    if ctx.attr.mode == "mix":
        if not ctx.attr.task:
            fail("mix_local mode='mix' requires task")
        args = prefix + [
            "-s",
            "elixir",
            "start_cli",
            "-extra",
            "-e",
            MIX_EVAL,
            "--",
            ctx.attr.task,
        ] + ctx.attr.task_args
    elif ctx.attr.mode == "iex":
        args = prefix + [
            "-user",
            "elixir",
            "+iex",
            "-s",
            "elixir",
            "start_cli",
            "-extra",
            "--no-halt",
            "+iex",
            "-S",
            "mix",
        ] + ctx.attr.task_args
    else:
        if not ctx.attr.module or not ctx.attr.function:
            fail("mix_local mode='elixir' requires module and function")
        args = prefix + [
            "-s",
            ctx.attr.module,
            ctx.attr.function,
            "-extra",
        ] + ctx.attr.task_args

    erl_libs = [path_join(toolchain.elixirinfo.elixir_home_short_path, "lib")]
    for dependency in dependencies:
        for lib_dir in dependency[ErlangAppInfo].lib_dirs_short_path:
            if lib_dir not in erl_libs:
                erl_libs.append(lib_dir)

    validate_user_env(ctx.attr.env)
    environment = otp_runtime_env(toolchain.otpinfo, runfiles = True)
    environment.update(ctx.attr.env)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "ERL_LIBS": ":".join(erl_libs),
        "HEX_OFFLINE": "true",
        "LANG": "C",
        "LC_ALL": "C",
        "MIX_ENV": ctx.attr.mix_env,
        "MIX_OS_CONCURRENCY_LOCK": "false",
        "RULES_ELIXIR_MIX_EXS": project.mix_config.basename,
        "RULES_ELIXIR_MIX_CHILD_ERL_AFLAGS": erl_env_flags(runtime_path_erl_args() + (["-crypto", "fips_mode", "true"] if toolchain.otpinfo.fips == "required" else [])),
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    if toolchain.otpinfo.fips == "required":
        environment["RULES_ELIXIR_MIX_FIPS_REQUIRED"] = "true"

    fingerprint_files = [app.compile_fingerprint, app.project_fingerprint]
    fingerprint_files.extend([dependency[ErlangAppInfo].compile_fingerprint for dependency in dependencies])
    fingerprint_files.extend([
        dependency[ErlangAppInfo].project_fingerprint
        for dependency in dependencies
        if dependency[ErlangAppInfo].project_fingerprint
    ])
    runfiles = ctx.runfiles(
        files = [manifest, context_fingerprint, driver] + application_project_files + [file for dependency in dependencies for file in dependency[ErlangAppInfo].project_files] + fingerprint_files,
        transitive_files = depset(transitive = [
            toolchain.runtime_files,
            crypto_runtime_files(toolchain.otpinfo),
        ]),
    ).merge(ctx.attr.lib[DefaultInfo].default_runfiles)
    for dependency in dependencies:
        runfiles = runfiles.merge(dependency[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = test_erl_launcher(ctx, toolchain.otpinfo), runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
    ]

mix_local = rule(
    implementation = _mix_local_impl,
    attrs = {
        "lib": attr.label(mandatory = True, providers = [ErlangAppInfo, MixProjectInfo]),
        "function": attr.string(),
        "mode": attr.string(default = "mix", values = ["elixir", "iex", "mix"]),
        "module": attr.string(),
        "task": attr.string(),
        "task_args": attr.string_list(),
        "mix_env": attr.string(default = "dev"),
        "env": attr.string_dict(),
        "_driver": attr.label(
            default = Label("//private:mix_local_driver.erl"),
            allow_single_file = [".erl"],
        ),
    },
    executable = True,
    toolchains = ["//:toolchain_type"],
)
