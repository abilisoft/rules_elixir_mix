"""Shell-free Mix release assembly."""

load("//private:beam_info.bzl", "ErlangAppInfo", "flat_compile_deps", "flat_deps")
load("//private:elixir_protocols.bzl", "ElixirProtocolInfo")
load("//private:mix_execution.bzl", "run_mix_action")
load("//private:mix_info.bzl", "MixProjectInfo")
load("//private:release_info.bzl", "ReleaseInfo")

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _build_manifest(ctx, build_root, mix_env, apps):
    entries = []
    for app in apps:
        info = app[ErlangAppInfo]
        if len(info.lib_dirs) != 1:
            fail("release application {} must expose exactly one build root".format(info.app_name))
        entries.append((
            info.lib_dirs[0] + "/" + info.app_name,
            "/".join([build_root.path, mix_env, "lib", info.app_name]),
        ))
    if ctx.attr.protocols:
        entries.append((
            ctx.attr.protocols[ElixirProtocolInfo].directory.path,
            "/".join([build_root.path, mix_env, "consolidated"]),
        ))

    manifest = ctx.actions.declare_file(ctx.label.name + "_build_manifest")
    ctx.actions.write(
        manifest,
        "[{}].\n".format(", ".join([
            "{{{}, {}}}".format(_erl_string(source), _erl_string(destination))
            for source, destination in entries
        ])),
    )
    return manifest

def _term_string(value):
    return _erl_string(value)

def _json_string(value):
    return '"{}"'.format(
        value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t"),
    )

def _json_array(values):
    return "[{}]".format(",".join([_json_string(value) for value in values]))

def _json_object(values):
    return "{{{}}}".format(",".join([
        "{}:{}".format(_json_string(key), _json_string(values[key]))
        for key in sorted(values.keys())
    ]))

def _launch_template(value):
    return value.replace("{sysroot}", "{sdk_root}")

def _runtime_entry_sort_key(entry):
    return (len(entry.destination.split("/")), entry.destination)

def _validate_release_name(value):
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@-"
    if not value or value[0] not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_":
        fail("release_name '{}' must begin with a letter or underscore".format(value))
    if any([value[index] not in allowed for index in range(len(value))]):
        fail("release_name '{}' contains a character unsafe for a native launcher path".format(value))

def _build_crypto_release_inputs(ctx, sdk, release_name, fips_required):
    destinations = []
    for entry in sdk.runtime_entries:
        if entry.destination in destinations:
            fail("crypto SDK runtime payload maps more than one file to '{}'".format(entry.destination))
        destinations.append(entry.destination)
    tool_path = sdk.activation_tool_release_path
    if not any([
        entry.file.path == sdk.activation_tool.executable.path and entry.destination == tool_path
        for entry in sdk.runtime_entries
    ]):
        fail("crypto SDK activation executable is not staged exactly at '{}'".format(tool_path))

    copy_manifest = ctx.actions.declare_file(ctx.label.name + "_crypto_runtime_manifest")

    # Stage directory artifacts before explicitly mapped children. This lets a
    # normalized SDK expose a declared runtime directory such as lib/ together
    # with a more specific payload such as lib/ossl-modules/fips.so without the
    # parent copy deleting the child later in the same deterministic action.
    runtime_entries = sorted(sdk.runtime_entries, key = _runtime_entry_sort_key)
    ctx.actions.write(
        copy_manifest,
        "[{}].\n".format(", ".join([
            "{{{}, {}}}".format(_term_string(entry.file.path), _term_string(entry.destination))
            for entry in runtime_entries
        ])),
    )
    activation_config = ctx.actions.declare_file(ctx.label.name + "_crypto_activation.config")
    environment = "[{}]".format(", ".join([
        "{{{}, {}}}".format(_term_string(key), _term_string(sdk.runtime_environment[key]))
        for key in sorted(sdk.runtime_environment.keys())
    ]))
    ctx.actions.write(
        activation_config,
        "#{activation_tool => %s, activation_args => %s, runtime_environment => %s}.\n" % (
            _term_string(tool_path),
            "[{}]".format(", ".join([_term_string(value) for value in sdk.activation_args])),
            environment,
        ),
    )
    launch_config = ctx.actions.declare_file(ctx.label.name + "_crypto_launch.json")
    arguments = ["-noshell"]
    if fips_required:
        arguments.extend(["-crypto", "fips_mode", "true"])
    writable_sys_config = "{activation_root}/sys"
    arguments.extend([
        "-s",
        "elixir",
        "start_cli",
        "-mode",
        "embedded",
        "-config",
        writable_sys_config,
        "-boot",
        "{release_root}/releases/{release_version}/start",
        "-boot_var",
        "RELEASE_LIB",
        "{release_root}/lib",
        "-args_file",
        "{release_root}/releases/{release_version}/vm.args",
        "-extra",
        "--no-halt",
    ])
    launch_environment = {
        "BINDIR": "{release_root}/erts-{erts_version}/bin",
        "EMU": "beam",
        "HOME": "{activation_root}/home",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "{release_root}/erts-{erts_version}/bin",
        "PROGNAME": release_name,
        "RELEASE_MODE": "embedded",
        "RELEASE_NAME": release_name,
        "RELEASE_ROOT": "{release_root}",
        "RELEASE_SYS_CONFIG": writable_sys_config,
        "RELEASE_TMP": "{activation_root}/tmp",
        "RELEASE_VSN": "{release_version}",
        "ROOTDIR": "{release_root}",
        "TZ": "UTC",
    }
    runtime_program = "{release_root}/erts-{erts_version}/bin/erlexec"
    if sdk.execution_wrapper:
        runtime_program = "{release_root}/erts-{erts_version}/bin/.real-erlexec"
    runtime_environment = {
        key: _launch_template(sdk.runtime_environment[key])
        for key in sdk.runtime_environment
    }
    runtime_environment.update({
        key: _launch_template(sdk.execution_wrapper_environment[key]).replace("{program}", runtime_program)
        for key in sdk.execution_wrapper_environment
    })
    ctx.actions.write(
        launch_config,
        "{" + ",".join([
            '"schema":1',
            '"command":"start"',
            '"sdk_root":"{release_root}/.rules_elixir_mix/crypto_sdk"',
            '"activation_root_environment":"RULES_ELIXIR_MIX_CRYPTO_STATE"',
            '"activation_args":' + _json_array([_launch_template(value) for value in sdk.activation_args]),
            '"runtime_environment":' + _json_object(runtime_environment),
            '"program":' + _json_string(runtime_program),
            '"arguments":' + _json_array(arguments),
            '"environment":' + _json_object(launch_environment),
            '"writable_copies":[{' + ",".join([
                '"source":"{release_root}/releases/{release_version}/sys.config"',
                '"destination":"{activation_root}/sys.config"',
            ]) + "}]",
            '"unset_environment":' + _json_array([
                "BASH_ENV",
                "DYLD_LIBRARY_PATH",
                "DYLD_INSERT_LIBRARIES",
                "ELIXIR_ERL_OPTIONS",
                "ERL_AFLAGS",
                "ERL_FLAGS",
                "ERL_LIBS",
                "ERL_ROOTDIR",
                "ERL_ZFLAGS",
                "LD_LIBRARY_PATH",
                "LD_PRELOAD",
            ]),
        ]) + "}\n",
    )
    return copy_manifest, activation_config, launch_config

def _mix_release_impl(ctx):
    otp = ctx.toolchains["//:toolchain_type"].otpinfo
    if ctx.attr.fips == "required" and otp.fips != "required":
        fail("mix_release(fips='required') requires a FIPS-required OTP toolchain")
    if ctx.attr.fips == "disabled" and otp.fips == "required":
        fail("a FIPS-required OTP toolchain cannot produce a FIPS-disabled release")
    fips_required = otp.fips == "required"
    crypto_activation = otp.crypto_sdk != None and otp.crypto_sdk.activation_tool != None
    app_info = ctx.attr.application[ErlangAppInfo]
    mix_info = ctx.attr.application[MixProjectInfo]
    if ctx.attr.mix_env != mix_info.mix_env:
        fail("mix_release mix_env '{}' does not match application {} compiled with mix_env '{}'".format(
            ctx.attr.mix_env,
            ctx.attr.application.label,
            mix_info.mix_env,
        ))
    app_name = ctx.attr.app_name or app_info.app_name
    release_name = ctx.attr.release_name or app_name
    _validate_release_name(release_name)
    mix_config = ctx.file.mix_config or mix_info.mix_config

    release_dir = ctx.actions.declare_directory(ctx.label.name + "_release")
    build_root = struct(path = release_dir.path + ".build")
    release_apps = flat_deps([ctx.attr.application] + ctx.attr.deps)
    action_deps = flat_compile_deps([ctx.attr.application] + ctx.attr.deps)
    manifest = _build_manifest(ctx, build_root, ctx.attr.mix_env, release_apps)
    files = [mix_config]
    files.extend(mix_info.project_files.to_list())
    files.extend(ctx.files.configs)
    files.extend(ctx.files.data)
    if ctx.file.lockfile:
        files.append(ctx.file.lockfile)
    files.append(manifest)
    if ctx.attr.protocols:
        files.extend(ctx.attr.protocols[DefaultInfo].files.to_list())

    crypto_manifest = None
    activation_config = None
    launch_config = None
    if crypto_activation:
        crypto_manifest, activation_config, launch_config = _build_crypto_release_inputs(
            ctx,
            otp.crypto_sdk,
            release_name,
            fips_required,
        )
        files.extend([
            crypto_manifest,
            activation_config,
            launch_config,
        ])
        files.extend([entry.file for entry in otp.crypto_sdk.runtime_entries])

    user_env = {
        key: ctx.expand_location(value, ctx.attr.data)
        for key, value in ctx.attr.env.items()
    }
    internal_env = {
        "RULES_ELIXIR_MIX_BUILD_MANIFEST": manifest.path,
        "RULES_ELIXIR_MIX_PRELOAD_DEPS": "true",
        "RULES_ELIXIR_MIX_PREPARE_COMPILED_PROJECT": "true",
        "RULES_ELIXIR_MIX_RELEASE_ROOT": release_dir.path,
        "RULES_ELIXIR_MIX_REMOVE_BUILD_ROOT": "true",
    }
    if ctx.attr.protocols:
        internal_env["RULES_ELIXIR_MIX_CONSOLIDATE_PROTOCOLS"] = "true"
        internal_env["RULES_ELIXIR_MIX_RELEASE_PROTOCOLS"] = ctx.attr.protocols[ElixirProtocolInfo].directory.path
    if fips_required:
        files.append(ctx.file._crypto_release_enforcement)
        internal_env.update({
            "RULES_ELIXIR_MIX_FIPS_RELEASE_ENFORCEMENT": ctx.file._crypto_release_enforcement.path,
            "RULES_ELIXIR_MIX_FIPS_RELEASE_ROOT": release_dir.path,
        })
    if crypto_activation:
        internal_env.update({
            "RULES_ELIXIR_MIX_CRYPTO_ACTIVATION_CONFIG": activation_config.path,
            "RULES_ELIXIR_MIX_CRYPTO_LAUNCH_CONFIG": launch_config.path,
            "RULES_ELIXIR_MIX_CRYPTO_LAUNCH_NAME": release_name,
            "RULES_ELIXIR_MIX_CRYPTO_LAUNCH_TOOL": otp.crypto_sdk.activation_tool_release_path,
            "RULES_ELIXIR_MIX_CRYPTO_RELEASE_MANIFEST": crypto_manifest.path,
        })
    internal_env["RULES_ELIXIR_MIX_OUTPUT"] = release_dir.path
    release_args = ([ctx.attr.release_name] if ctx.attr.release_name else []) + [
        "--path",
        "__RULES_ELIXIR_MIX_OUTPUT__",
        "--no-archives-check",
        "--no-compile",
        "--no-deps-check",
        "--overwrite",
    ]
    run_mix_action(
        ctx = ctx,
        task = "release",
        task_args = release_args,
        mix_config = mix_config,
        mix_env = ctx.attr.mix_env,
        build_root = build_root.path,
        deps = action_deps,
        inputs = files,
        project_inputs = [mix_config] + mix_info.project_files.to_list() + ctx.files.configs + ctx.files.data + ([ctx.file.lockfile] if ctx.file.lockfile else []),
        project_entries = mix_info.project_entries,
        outputs = [release_dir],
        internal_env = internal_env,
        user_env = user_env,
        stage_build_cache = False,
        mnemonic = "MIXRELEASE",
    )

    return [
        DefaultInfo(
            files = depset([release_dir]),
            runfiles = ctx.runfiles(files = [release_dir]),
        ),
        ReleaseInfo(
            name = release_name,
            version = None,
            env = ctx.attr.mix_env,
            app_name = app_name,
            crypto_activation = crypto_activation,
            fips = "required" if fips_required else "disabled",
        ),
    ]

mix_release = rule(
    implementation = _mix_release_impl,
    attrs = {
        "app_name": attr.string(),
        "application": attr.label(mandatory = True, providers = [MixProjectInfo, ErlangAppInfo]),
        "configs": attr.label_list(allow_files = [".exs"]),
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "lockfile": attr.label(allow_single_file = True),
        "mix_config": attr.label(allow_single_file = [".exs"]),
        "protocols": attr.label(providers = [ElixirProtocolInfo]),
        "env": attr.string_dict(),
        "fips": attr.string(default = "toolchain", values = ["disabled", "required", "toolchain"]),
        "mix_env": attr.string(default = "prod", values = ["prod", "dev", "test", "staging"]),
        "release_name": attr.string(),
        "_crypto_release_enforcement": attr.label(
            default = Label("//private:crypto_release_enforcement.exs"),
            allow_single_file = [".exs"],
        ),
    },
    provides = [ReleaseInfo],
    toolchains = ["//:toolchain_type"],
)
