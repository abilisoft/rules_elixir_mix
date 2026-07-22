"""Build pristine Elixir sources against a declared OTP runtime."""

load("//private:beam_info.bzl", "OtpInfo", "erl_env_flags", "execution_erlexec", "execution_erts_bin", "execution_root_path", "otp_runtime_env", "otp_runtime_erl_args", "path_join")
load("//private:elixir_info.bzl", "ElixirInfo", "otp_info_from_dependency")
load("//private:runtime_archive_info.bzl", "BeamRuntimeSourceInfo")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[N,S|R]=A,{ok,artifact_normalizer,NB}=compile:file(N,[binary,report_errors,report_warnings]),{module,artifact_normalizer}=code:load_binary(artifact_normalizer,N,NB),C=compile:file(S,[binary,report_errors,report_warnings]),M=element(2,C),B=element(3,C),{module,M}=code:load_binary(M,S,B),M:main(R),halt()."

def _erl_string(value):
    return '"{}"'.format(
        value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t"),
    )

def _common_source_root(files):
    if not files:
        fail("elixir_source_release requires non-empty srcs")
    if len(files) == 1 and files[0].is_directory:
        return files[0].short_path

    common = files[0].short_path.split("/")[:-1]
    for file in files[1:]:
        parts = file.short_path.split("/")[:-1]
        limit = min(len(common), len(parts))
        index = 0
        for candidate in range(limit):
            if common[candidate] != parts[candidate]:
                break
            index = candidate + 1
        common = common[:index]
    if not common:
        fail("elixir_source_release srcs must share one source root")
    return "/".join(common)

def _source_entries(files):
    root = _common_source_root(files)
    entries = []
    for file in files:
        relative = "." if file.short_path == root else file.short_path[len(root) + 1:]
        entries.append("{{{}, {}}}".format(_erl_string(file.path), _erl_string(relative)))
    return entries

def _path_directories(files):
    result = []
    for file in files:
        directory = file.path if file.is_directory else file.dirname
        if directory and directory not in result:
            result.append(directory)
    return result

def _term_list(values):
    return "[{}]".format(", ".join([_erl_string(value) for value in values]))

def _validate_make_options(options):
    owned_variables = ["BINDIR", "ELIXIRC", "ERL_AFLAGS", "ERL_COMPILER_OPTIONS", "GENERATE_APP", "GNUMAKEFLAGS", "HOME", "MAKEFLAGS", "MFLAGS", "PATH", "SHELL", "TMPDIR"]
    forbidden_options = ["-C", "--directory", "-e", "--environment-overrides", "-f", "--file", "-I", "--include-dir", "--eval", "-j", "--jobs"]
    attached_short_options = ["-C", "-f", "-I", "-j"]
    for option in options:
        assignment = option.split("=", 1)[0]
        if assignment in owned_variables:
            fail("make_options may not override rule-owned variable '{}'".format(assignment))
        if any([option == flag or option.startswith(flag + "=") for flag in forbidden_options]) or any([option.startswith(flag) for flag in attached_short_options]):
            fail("make_options may not override Make execution policy with '{}'".format(option))

def _elixir_source_release_impl(ctx):
    if ctx.attr.jobs < 1 or ctx.attr.jobs > 64:
        fail("elixir_source_release jobs must be between 1 and 64")
    _validate_make_options(ctx.attr.make_options)

    otp = otp_info_from_dependency(ctx.attr.otp)
    child_erl_aflags = erl_env_flags(
        otp_runtime_erl_args(otp) +
        ["+fnu"],
    )
    inherited_sdk_environment = sorted({
        key: True
        for key in (
            (otp.crypto_sdk.execution_wrapper_environment.keys() if otp.crypto_sdk else [])
        )
    }.keys())
    output = ctx.actions.declare_directory(ctx.label.name + "_runtime")
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")
    ctx.actions.write(version_file, ctx.attr.version + "\n")

    tool_files = ctx.files.posix_tools
    posix_tool_executables = []
    posix_tools = []
    for target in ctx.attr.posix_tools:
        files_to_run = target[DefaultInfo].files_to_run
        if files_to_run.executable == None:
            fail("posix_tools entries must be executable targets: {}".format(target.label))
        posix_tool_executables.append(files_to_run.executable)
        posix_tools.append(files_to_run)
    if not posix_tool_executables:
        fail("elixir_source_release requires a hermetic POSIX toolbox")
    otp_exec_erts_bin = execution_erts_bin(otp)
    path_directories = _path_directories([
        ctx.executable.bash,
        ctx.executable.make,
    ] + posix_tool_executables) + [otp_exec_erts_bin]
    environment = {
        "BINDIR": "{path, " + _erl_string(otp_exec_erts_bin) + "}",
        "EMU": _erl_string("beam"),
        "ERL_ROOTDIR": "{path, " + _erl_string(otp.erlang_home) + "}",
        "PATH": "{path_list, " + _term_list(path_directories) + "}",
        "PROGNAME": _erl_string("erl"),
        "ROOTDIR": "{path, " + _erl_string(otp.erlang_home) + "}",
        "SHELL": "{path, " + _erl_string(ctx.executable.bash.path) + "}",
    }
    environment_term = "#{{{}}}".format(", ".join([
        "{} => {}".format(_erl_string(key), environment[key])
        for key in sorted(environment.keys())
    ]))
    config = ctx.actions.declare_file(ctx.label.name + "_build.config")
    ctx.actions.write(
        config,
        "#{\n" + ",\n".join([
            "  bash => {}".format(_erl_string(ctx.executable.bash.path)),
            "  environment => {}".format(environment_term),
            "  erlexec => {}".format(_erl_string(path_join(otp_exec_erts_bin, "erlexec"))),
            "  erl_aflags => {}".format(_erl_string(child_erl_aflags)),
            "  escript => {}".format(_erl_string(path_join(otp_exec_erts_bin, "escript"))),
            "  inherited_sdk_environment => {}".format(_term_list(inherited_sdk_environment)),
            "  jobs => {}".format(ctx.attr.jobs),
            "  make => {}".format(_erl_string(ctx.executable.make.path)),
            "  make_options => {}".format(_term_list(ctx.attr.make_options)),
            "  output => {}".format(_erl_string(output.path)),
            "  otp_release => {}".format(_erl_string(otp.version.split(".")[0])),
            "  sources => [{}]".format(",\n    ".join(_source_entries(ctx.files.srcs))),
            "  version => {}".format(_erl_string(ctx.attr.version)),
        ]) + "\n}.\n",
    )

    args = ctx.actions.args()
    args.add_all([
        "-noshell",
        "+fnu",
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._normalizer,
        ctx.file._driver,
        config,
        execution_root_path("."),
    ])
    action_env = otp_runtime_env(otp)
    action_env.update({
        "HOME": output.path + ".work/driver_home",
        "LANG": "C",
        "LC_ALL": "C",
        "RULES_ELIXIR_MIX_CRYPTO_STATE": output.path + ".work/crypto_state",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = execution_erlexec(otp),
        arguments = [args],
        inputs = depset(
            direct = ctx.files.srcs + tool_files + [ctx.file._driver, ctx.file._normalizer, config],
            transitive = [otp.runtime_files],
        ),
        tools = [
            ctx.attr.bash[DefaultInfo].files_to_run,
            ctx.attr.make[DefaultInfo].files_to_run,
        ] + posix_tools,
        outputs = [output],
        env = action_env,
        execution_requirements = {"block-network": "1"},
        mnemonic = "ELIXIRBUILD",
        progress_message = "Building Elixir {} from source".format(ctx.attr.version),
        use_default_shell_env = False,
    )

    runtime_files = depset(
        direct = [output, version_file],
        transitive = [otp.runtime_files],
    )
    return [
        DefaultInfo(files = runtime_files),
        otp,
        BeamRuntimeSourceInfo(
            kind = "elixir",
            root = output,
            root_relative_path = "",
            version = ctx.attr.version,
        ),
        ElixirInfo(
            version = ctx.attr.version,
            elixir_home = output.path,
            elixir_home_short_path = output.short_path,
            runtime_files = runtime_files,
            version_file = version_file,
        ),
    ]

elixir_source_release = rule(
    implementation = _elixir_source_release_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "srcs": attr.label_list(mandatory = True, allow_files = True),
        "otp": attr.label(
            mandatory = True,
            providers = [[OtpInfo], [platform_common.ToolchainInfo]],
        ),
        "bash": attr.label(mandatory = True, executable = True, allow_files = True, cfg = "exec"),
        "make": attr.label(mandatory = True, executable = True, allow_files = True, cfg = "exec"),
        "posix_tools": attr.label_list(mandatory = True, allow_files = True, cfg = "exec"),
        "make_options": attr.string_list(),
        "jobs": attr.int(default = 8),
        "_driver": attr.label(
            default = Label("//private:elixir_build_driver.erl"),
            allow_single_file = [".erl"],
        ),
        "_normalizer": attr.label(
            default = Label("//private:artifact_normalizer.erl"),
            allow_single_file = [".erl"],
        ),
    },
)
