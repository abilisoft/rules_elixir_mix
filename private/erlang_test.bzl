"""Shell-free EUnit and Common Test rules."""

load("//private:beam_info.bzl", "ErlangAppInfo", "crypto_runtime_files", "erl_env_flags", "fips_erl_args", "flat_runtime_deps", "otp_runtime_env", "prepare_crypto_runtime", "runtime_path_erl_args", "test_erl_launcher")

_EUNIT_EVAL = "{ok,_}=application:ensure_all_started(eunit),A=[{application,list_to_atom(N)}||N<-init:get_plain_arguments()],case eunit:test(A,[verbose]) of ok->halt(0);_->halt(1) end."
_COMMON_TEST_EVAL = "[D,C]=init:get_plain_arguments(),{ok,common_test_driver,B}=compile:file(D,[binary,report_errors,report_warnings]),{module,common_test_driver}=code:load_binary(common_test_driver,D,B),common_test_driver:main([C]),halt()."

def _erl_string(value):
    return '"{}"'.format(
        value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t"),
    )

def _erl_atom(value):
    return "'{}'".format(value.replace("\\", "\\\\").replace("'", "\\'"))

def _term_list(values, renderer):
    return "[{}]".format(", ".join([renderer(value) for value in values]))

def _validate_atom_name(name, attribute):
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@"
    if not name or name[0] not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_":
        fail("{} value '{}' must begin with a letter or underscore".format(attribute, name))
    if any([name[index] not in allowed for index in range(len(name))]):
        fail("{} value '{}' contains an invalid Erlang atom character".format(attribute, name))

def _validate_suite_data_destination(destination, suites):
    if destination.startswith("/"):
        fail("suite_data destination '{}' must be relative".format(destination))
    parts = destination.split("/")
    if len(parts) < 2 or any([not part or part in [".", ".."] for part in parts]):
        fail("suite_data destination '{}' must be <suite>/<relative path> without empty, '.' or '..' components".format(destination))
    if parts[0] not in suites:
        fail("suite_data destination '{}' names suite '{}', which is not in suites".format(destination, parts[0]))
    return parts[0], "/".join(parts[1:])

def _test_result(ctx, expression, names, extra_runfiles = [], plain_args = []):
    toolchain = ctx.toolchains["//:otp_toolchain_type"]
    activation = prepare_crypto_runtime(
        ctx,
        toolchain.otpinfo,
        ctx.label.name + "_crypto_state",
        runfiles = True,
    )
    apps = flat_runtime_deps(ctx.attr.apps)
    lib_dirs = []
    for app in apps:
        for directory in app[ErlangAppInfo].lib_dirs_short_path:
            if directory not in lib_dirs:
                lib_dirs.append(directory)
    args = runtime_path_erl_args() + [
        "-noshell",
    ] + fips_erl_args(toolchain.otpinfo, runfiles = True, activate = False) + [
        "-eval",
        expression,
        "-extra",
    ] + names + plain_args
    environment = otp_runtime_env(toolchain.otpinfo, runfiles = True)
    environment.update(activation.environment)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "ERL_LIBS": ":".join(lib_dirs),
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    runfiles = ctx.runfiles(
        files = extra_runfiles,
        transitive_files = depset(transitive = [
            toolchain.runtime_files,
            crypto_runtime_files(toolchain.otpinfo),
            activation.files,
        ]),
    )
    for app in apps:
        runfiles = runfiles.merge(app[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = test_erl_launcher(ctx, toolchain.otpinfo), runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
    ]

def _eunit_test_impl(ctx):
    names = ctx.attr.app_names or [app[ErlangAppInfo].app_name for app in ctx.attr.apps]
    return _test_result(ctx, _EUNIT_EVAL, names)

erlang_eunit_test = rule(
    implementation = _eunit_test_impl,
    attrs = {
        "apps": attr.label_list(mandatory = True, providers = [ErlangAppInfo]),
        "app_names": attr.string_list(),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)

def _common_test_impl(ctx):
    if not ctx.attr.suites:
        fail("erlang_common_test requires explicit suite module names")
    for suite in ctx.attr.suites:
        _validate_atom_name(suite, "suites")
    for group in ctx.attr.groups:
        _validate_atom_name(group, "groups")
    for case in ctx.attr.cases:
        _validate_atom_name(case, "cases")
    for hook in ctx.attr.hooks:
        _validate_atom_name(hook, "hooks")
    if ctx.attr.repeat < 1:
        fail("repeat must be at least one")
    if ctx.attr.verbosity < 0 or ctx.attr.verbosity > 100:
        fail("verbosity must be between zero and 100")

    data_files = []
    data_entries = []
    destinations = {}
    for target, destination in ctx.attr.suite_data.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("suite_data target {} must provide exactly one file or tree artifact".format(target.label))
        suite, relative = _validate_suite_data_destination(destination, ctx.attr.suites)
        canonical_destination = suite + "/" + relative
        if canonical_destination in destinations:
            fail("multiple suite_data inputs map to '{}'".format(canonical_destination))
        destinations[canonical_destination] = True
        file = files[0]
        data_files.append(file)
        data_entries.append("{{{}, {}, {}}}".format(
            _erl_string(file.short_path),
            _erl_atom(suite),
            _erl_string(relative),
        ))

    config = ctx.actions.declare_file(ctx.label.name + "_common_test.config")
    ctx.actions.write(
        config,
        "#{\n" + ",\n".join([
            "  cases => {}".format(_term_list(ctx.attr.cases, _erl_atom)),
            "  config_files => {}".format(_term_list([file.short_path for file in ctx.files.config], _erl_string)),
            "  groups => {}".format(_term_list(ctx.attr.groups, _erl_atom)),
            "  hooks => {}".format(_term_list(ctx.attr.hooks, _erl_atom)),
            "  repeat => {}".format(ctx.attr.repeat),
            "  suite_data => [{}]".format(", ".join(data_entries)),
            "  suites => {}".format(_term_list(ctx.attr.suites, _erl_atom)),
            "  verbosity => {}".format(ctx.attr.verbosity),
        ]) + "\n}.\n",
    )
    return _test_result(
        ctx,
        _COMMON_TEST_EVAL,
        [],
        extra_runfiles = [ctx.file._driver, config] + ctx.files.config + data_files,
        plain_args = [ctx.file._driver.short_path, config.short_path],
    )

erlang_common_test = rule(
    implementation = _common_test_impl,
    attrs = {
        "apps": attr.label_list(mandatory = True, providers = [ErlangAppInfo]),
        "suites": attr.string_list(mandatory = True),
        "cases": attr.string_list(),
        "config": attr.label_list(allow_files = True),
        "groups": attr.string_list(),
        "hooks": attr.string_list(),
        "repeat": attr.int(default = 1),
        "suite_data": attr.label_keyed_string_dict(allow_files = True),
        "verbosity": attr.int(default = 50),
        "_driver": attr.label(
            default = Label("//private:common_test_driver.erl"),
            allow_single_file = [".erl"],
        ),
    },
    test = True,
    toolchains = ["//:otp_toolchain_type"],
)
