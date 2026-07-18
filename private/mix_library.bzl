"""Shell-free rules for compiling Mix projects."""

load("//private:beam_info.bzl", "ErlangAppInfo", "compile_depset", "flat_compile_deps", "path_join", "runtime_depset", "type_depset")
load("//private:elixir_priv.bzl", "ElixirPrivInfo")
load("//private:elixir_source.bzl", "ElixirSourceInfo")
load("//private:mix_execution.bzl", "run_mix_action")
load("//private:mix_info.bzl", "MixProjectInfo")
load("//private:native_build.bzl", "NATIVE_EXEC_GROUP", "native_build_context", "use_native_cc_toolchain")

_MixCompileInfo = provider(
    doc = "Internal result of a Mix compile action.",
    fields = {
        "fingerprint": "Deterministic compiled-application fingerprint.",
        "project_fingerprint": "Deterministic staged source-project fingerprint.",
    },
)

def _erl_string(value):
    return '"{}"'.format(
        value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t"),
    )

def _priv_destination(file):
    short_path = file.short_path
    marker = "/priv/"
    if marker in short_path:
        return short_path.split(marker, 1)[1]
    if short_path.startswith("priv/"):
        return short_path[len("priv/"):]
    return file.basename

def _write_mapping_manifest(ctx, suffix, entries):
    if not entries:
        return None
    destinations = []
    for entry in entries:
        if entry.destination in destinations:
            fail("multiple {} inputs map to '{}' for {}".format(suffix, entry.destination, ctx.label))
        destinations.append(entry.destination)
    manifest = ctx.actions.declare_file(ctx.label.name + "_" + suffix + "_manifest")
    ctx.actions.write(
        manifest,
        "[{}].\n".format(", ".join([
            "{{{}, {}}}".format(_erl_string(entry.source.path), _erl_string(entry.destination))
            for entry in entries
        ])),
    )
    return manifest

def _precompiled_native_manifest(ctx):
    entries = []
    basenames = {}
    for file in ctx.files.precompiled_native_artifacts:
        if file.basename in basenames:
            fail("precompiled native artifacts {} and {} share basename '{}'".format(basenames[file.basename], file, file.basename))
        basenames[file.basename] = file
        entries.append(struct(destination = file.basename, source = file))
    return _write_mapping_manifest(ctx, "precompiled_native", entries)

def _header_destination(file):
    marker = "/include/"
    if marker in file.short_path:
        return file.short_path.split(marker, 1)[1]
    if file.short_path.startswith("include/"):
        return file.short_path[len("include/"):]
    return file.basename

def _project_entries(files, mix_config, generated_entries):
    root = mix_config.short_path.rsplit("/", 1)[0] if "/" in mix_config.short_path else ""
    prefix = root.rstrip("/") + "/" if root else ""
    result = []
    destinations = {}
    generated_sources = {entry.source.path: True for entry in generated_entries}
    for entry in generated_entries:
        if entry.destination in destinations and destinations[entry.destination].path != entry.source.path:
            fail("generated project inputs {} and {} both map to '{}'".format(destinations[entry.destination], entry.source, entry.destination))
        destinations[entry.destination] = entry.source
        result.append(entry)
    for file in files:
        if file.path in generated_sources:
            continue
        if prefix and file.short_path.startswith(prefix):
            relative = file.short_path[len(prefix):]
        elif not prefix and not file.short_path.startswith("../"):
            relative = file.short_path
        else:
            fail("project input {} is outside source root '{}' and requires elixir_generated_source".format(file, root or "."))
        if relative in destinations:
            if destinations[relative].path != file.path:
                fail("project inputs {} and {} both map to '{}'".format(destinations[relative], file, relative))
            continue
        destinations[relative] = file
        result.append(struct(destination = relative, source = file))
    return result

def _exclude_generated_destinations(files, mix_config, generated_entries):
    root = mix_config.short_path.rsplit("/", 1)[0] if "/" in mix_config.short_path else ""
    prefix = root.rstrip("/") + "/" if root else ""
    generated_destinations = {entry.destination: True for entry in generated_entries}
    result = []
    for file in files:
        if prefix and file.short_path.startswith(prefix):
            relative = file.short_path[len(prefix):]
        elif not prefix and not file.short_path.startswith("../"):
            relative = file.short_path
        else:
            relative = None
        if relative not in generated_destinations:
            result.append(file)
    return result

def _mix_compile_impl(ctx):
    build_root = ctx.actions.declare_directory(ctx.label.name + "_build")
    fingerprint = ctx.actions.declare_file(ctx.label.name + "_fingerprint")
    project_fingerprint = ctx.actions.declare_file(ctx.label.name + "_project_fingerprint")
    generated_entries = [
        entry
        for target in ctx.attr.generated_srcs
        for entry in target[ElixirSourceInfo].entries
    ]
    generated_files = [entry.source for entry in generated_entries]
    source_files = _exclude_generated_destinations(ctx.files.srcs, ctx.file.mix_config, generated_entries)
    project_files = [ctx.file.mix_config] + ctx.files.config + ctx.files.data
    if ctx.file.lockfile:
        project_files.append(ctx.file.lockfile)

    env = {
        key: ctx.expand_location(value, ctx.attr.data)
        for key, value in ctx.attr.env.items()
    }
    task_args = [
        "--no-archives-check",
        "--no-deps-check",
        "--no-prune-code-paths",
        "--no-protocol-consolidation",
    ]
    if ctx.attr.warnings_as_errors:
        task_args = ["--warnings-as-errors"] + task_args

    priv_entries = []
    for file in ctx.files.priv:
        priv_entries.append(struct(
            destination = _priv_destination(file),
            source = file,
        ))
    for target in ctx.attr.priv_entries:
        priv_entries.extend(target[ElixirPrivInfo].entries)
    priv_manifest = _write_mapping_manifest(ctx, "priv", priv_entries)
    include_entries = [
        struct(destination = _header_destination(file), source = file)
        for file in ctx.files.include
    ]
    include_manifest = _write_mapping_manifest(ctx, "include", include_entries)
    precompiled_native_manifest = _precompiled_native_manifest(ctx)

    internal_env = {
        "RULES_ELIXIR_MIX_APP": ctx.attr.app_name,
        "RULES_ELIXIR_MIX_ARTIFACT_NORMALIZER": ctx.file._artifact_normalizer.path,
        "RULES_ELIXIR_MIX_BUILD_ROOT": build_root.path,
        "RULES_ELIXIR_MIX_COMPILE_FINGERPRINT": fingerprint.path,
        "RULES_ELIXIR_MIX_PROJECT_FINGERPRINT": project_fingerprint.path,
        "RULES_ELIXIR_MIX_VERIFY_APP": "true",
    }
    if priv_manifest:
        internal_env.update({
            "RULES_ELIXIR_MIX_PRIV_MANIFEST": priv_manifest.path,
        })
    if include_manifest:
        internal_env["RULES_ELIXIR_MIX_INCLUDE_MANIFEST"] = include_manifest.path
    if precompiled_native_manifest:
        internal_env["RULES_ELIXIR_MIX_PRECOMPILED_NATIVE_MANIFEST"] = precompiled_native_manifest.path

    if ctx.attr.native_build and (ctx.attr.native_make_jobs < 1 or ctx.attr.native_make_jobs > 64):
        fail("native_make_jobs must be between 1 and 64")
    native = native_build_context(ctx) if ctx.attr.native_build else None
    if native:
        internal_env.update(native.environment)

    run_mix_action(
        ctx = ctx,
        task = "compile",
        task_args = task_args,
        mix_config = ctx.file.mix_config,
        mix_env = ctx.attr.mix_env,
        build_root = build_root.path,
        deps = flat_compile_deps(ctx.attr.compile_deps + ctx.attr.type_deps + ctx.attr.runtime_deps),
        inputs = source_files + generated_files + ctx.files.include + ctx.files.precompiled_native_artifacts + [entry.source for entry in priv_entries] + project_files + [ctx.file._artifact_normalizer] + ([priv_manifest] if priv_manifest else []) + ([include_manifest] if include_manifest else []) + ([precompiled_native_manifest] if precompiled_native_manifest else []),
        project_inputs = source_files + generated_files + ctx.files.include + ctx.files.priv + project_files,
        project_entries = generated_entries,
        outputs = [build_root, fingerprint, project_fingerprint],
        internal_env = internal_env,
        user_env = env,
        action_inputs = native.inputs if native else None,
        action_tools = native.tools if native else [],
        action_execution_requirements = native.execution_requirements if native else {},
        exec_group = NATIVE_EXEC_GROUP if native else None,
        mnemonic = "MIXCOMPILE",
    )

    return [
        DefaultInfo(
            files = depset([build_root]),
            runfiles = ctx.runfiles(files = [build_root]),
        ),
        _MixCompileInfo(
            fingerprint = fingerprint,
            project_fingerprint = project_fingerprint,
        ),
    ]

def _mix_compile_attrs():
    return {
        "app_name": attr.string(mandatory = True),
        "mix_env": attr.string(default = "prod", values = ["prod", "test", "dev"]),
        "env": attr.string_dict(),
        "generated_srcs": attr.label_list(providers = [ElixirSourceInfo]),
        "mix_config": attr.label(mandatory = True, allow_single_file = [".exs"]),
        "srcs": attr.label_list(allow_files = [".ex", ".exs", ".erl", ".xrl", ".yrl", ".hrl", ".app.src"]),
        "config": attr.label_list(allow_files = [".ex", ".exs"]),
        "data": attr.label_list(allow_files = True),
        "compile_deps": attr.label_list(providers = [ErlangAppInfo]),
        "runtime_deps": attr.label_list(providers = [ErlangAppInfo]),
        "type_deps": attr.label_list(providers = [ErlangAppInfo]),
        "priv": attr.label_list(allow_files = True),
        "priv_entries": attr.label_list(providers = [ElixirPrivInfo]),
        "include": attr.label_list(allow_files = [".hrl"]),
        "lockfile": attr.label(allow_single_file = True),
        "native_build": attr.bool(default = False),
        "native_copts": attr.string_list(),
        "native_cxxopts": attr.string_list(),
        "native_linkopts": attr.string_list(),
        "native_make_jobs": attr.int(default = 4),
        "precompiled_native_artifacts": attr.label_list(allow_files = True),
        "warnings_as_errors": attr.bool(default = True),
        "_artifact_normalizer": attr.label(
            default = Label("//private:artifact_normalizer.erl"),
            allow_single_file = [".erl"],
        ),
    }

_mix_compile = rule(
    implementation = _mix_compile_impl,
    attrs = _mix_compile_attrs(),
    toolchains = ["//:toolchain_type"],
)

_mix_native_compile = rule(
    implementation = _mix_compile_impl,
    attrs = _mix_compile_attrs(),
    fragments = ["cpp"],
    exec_groups = {
        NATIVE_EXEC_GROUP: exec_group(
            toolchains = ["//:toolchain_type"] + use_native_cc_toolchain(),
        ),
    },
)

def _mix_library_info_impl(ctx):
    build_roots = ctx.attr.compile[DefaultInfo].files.to_list()
    project_files = [ctx.file.mix_config] + ctx.files.config + ctx.files.data + ctx.files.include
    if ctx.file.lockfile:
        project_files.append(ctx.file.lockfile)
    generated_entries = [
        entry
        for target in ctx.attr.generated_srcs
        for entry in target[ElixirSourceInfo].entries
    ]
    generated_files = [entry.source for entry in generated_entries]
    source_files = _exclude_generated_destinations(ctx.files.srcs, ctx.file.mix_config, generated_entries)
    all_project_files = project_files + source_files + generated_files + ctx.files.priv
    project_entries = _project_entries(all_project_files, ctx.file.mix_config, generated_entries)

    mapped_priv = [
        entry.source
        for target in ctx.attr.priv_entries
        for entry in target[ElixirPrivInfo].entries
    ]
    runfiles = ctx.runfiles(files = build_roots)
    for dep in ctx.attr.runtime_deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    compile_deps = compile_depset(ctx.attr.compile_deps + ctx.attr.type_deps + ctx.attr.runtime_deps)
    runtime_deps = runtime_depset(ctx.attr.runtime_deps)
    type_deps = type_depset(ctx.attr.type_deps + ctx.attr.runtime_deps)

    return [
        DefaultInfo(
            files = depset(build_roots),
            runfiles = runfiles,
        ),
        MixProjectInfo(
            lockfile = ctx.file.lockfile,
            mix_config = ctx.file.mix_config,
            mix_env = ctx.attr.mix_env,
            project_entries = project_entries,
            project_files = depset(all_project_files),
        ),
        ErlangAppInfo(
            app_name = ctx.attr.app_name,
            beam = build_roots,
            build_roots = [root.path for root in build_roots],
            build_roots_short_path = [root.short_path for root in build_roots],
            compile_deps = compile_deps,
            compile_fingerprint = ctx.attr.compile[_MixCompileInfo].fingerprint,
            lib_dirs = [path_join(root.path, ctx.attr.mix_env, "lib") for root in build_roots],
            lib_dirs_short_path = [path_join(root.short_path, ctx.attr.mix_env, "lib") for root in build_roots],
            deps = runtime_deps,
            direct_compile_deps = ctx.attr.compile_deps,
            direct_deps = ctx.attr.runtime_deps,
            direct_runtime_deps = ctx.attr.runtime_deps,
            direct_type_deps = ctx.attr.type_deps,
            extra_apps = [],
            include = ctx.files.include,
            license_files = [],
            priv = ctx.files.priv + mapped_priv,
            project_entries = project_entries,
            project_files = all_project_files,
            project_fingerprint = ctx.attr.compile[_MixCompileInfo].project_fingerprint,
            project_root_short_path = ctx.file.mix_config.short_path.rsplit("/", 1)[0] if "/" in ctx.file.mix_config.short_path else "",
            runtime_deps = runtime_deps,
            type_deps = type_deps,
            srcs = source_files + generated_files + ctx.files.config,
        ),
    ]

_mix_library_info = rule(
    implementation = _mix_library_info_impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "mix_env": attr.string(default = "prod"),
        "mix_config": attr.label(mandatory = True, allow_single_file = [".exs"]),
        "config": attr.label_list(allow_files = [".ex", ".exs"]),
        "compile": attr.label(mandatory = True),
        "data": attr.label_list(allow_files = True),
        "generated_srcs": attr.label_list(providers = [ElixirSourceInfo]),
        "compile_deps": attr.label_list(providers = [ErlangAppInfo]),
        "runtime_deps": attr.label_list(providers = [ErlangAppInfo]),
        "type_deps": attr.label_list(providers = [ErlangAppInfo]),
        "srcs": attr.label_list(allow_files = [".ex", ".exs", ".erl", ".xrl", ".yrl", ".hrl", ".app.src"]),
        "priv": attr.label_list(allow_files = True),
        "priv_entries": attr.label_list(providers = [ElixirPrivInfo]),
        "include": attr.label_list(allow_files = [".hrl"]),
        "lockfile": attr.label(allow_single_file = True),
    },
)

def _mix_library_impl(name, visibility, **kwargs):
    compile_keys = [
        "mix_env",
        "env",
        "srcs",
        "config",
        "data",
        "generated_srcs",
        "include",
        "native_build",
        "native_copts",
        "native_cxxopts",
        "native_linkopts",
        "native_make_jobs",
        "precompiled_native_artifacts",
        "warnings_as_errors",
    ]
    info_keys = ["mix_env", "srcs", "config", "data", "generated_srcs", "include"]
    common_keys = [
        "compatible_with",
        "exec_compatible_with",
        "features",
        "tags",
        "target_compatible_with",
        "testonly",
    ]

    compile_args = {key: value for key, value in kwargs.items() if key in compile_keys + common_keys}
    compile_args.update({
        "compile_deps": kwargs["compile_deps"],
        "mix_config": kwargs["mix_config"],
        "priv": kwargs["priv"],
        "priv_entries": kwargs["priv_entries"],
        "runtime_deps": kwargs["runtime_deps"],
        "type_deps": kwargs["type_deps"],
    })
    info_args = {key: value for key, value in kwargs.items() if key in info_keys + common_keys}
    info_args.update({
        "compile_deps": kwargs["compile_deps"],
        "mix_config": kwargs["mix_config"],
        "priv": kwargs["priv"],
        "priv_entries": kwargs["priv_entries"],
        "runtime_deps": kwargs["runtime_deps"],
        "type_deps": kwargs["type_deps"],
    })
    if kwargs["lockfile"]:
        compile_args["lockfile"] = kwargs["lockfile"]
        info_args["lockfile"] = kwargs["lockfile"]

    compile_rule = _mix_native_compile if kwargs.get("native_build", False) else _mix_compile
    compile_rule(
        name = name + "_compile",
        app_name = kwargs["app_name"],
        visibility = ["//visibility:private"],
        **compile_args
    )
    _mix_library_info(
        name = name,
        app_name = kwargs["app_name"],
        compile = ":" + name + "_compile",
        visibility = visibility,
        **info_args
    )

mix_library = macro(
    doc = "Compile one declared Mix/OTP application into a cacheable BEAM tree.",
    inherit_attrs = _mix_compile,
    attrs = {
        "compile_deps": attr.label_list(
            providers = [ErlangAppInfo],
            configurable = False,
            doc = "Direct applications available only during compilation.",
        ),
        "lockfile": attr.label(
            allow_single_file = True,
            configurable = False,
            doc = "Explicit checked-in mix.lock; dependency resolution never runs in an action.",
        ),
        "native_build": attr.bool(
            configurable = False,
            doc = "Resolve the selected execution platform's declared C/C++ and POSIX closure for this compile action only.",
        ),
        "runtime_deps": attr.label_list(
            providers = [ErlangAppInfo],
            configurable = False,
            doc = "Direct applications propagated into the runtime closure.",
        ),
        "type_deps": attr.label_list(
            providers = [ErlangAppInfo],
            configurable = False,
            doc = "Compile-only applications whose remote types are referenced by this application.",
        ),
        "tags": attr.string_list(configurable = False),
    },
    implementation = _mix_library_impl,
)
