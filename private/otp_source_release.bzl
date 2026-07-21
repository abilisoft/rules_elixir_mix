"""Hermetic OTP source build using explicit tools and an Erlang driver."""

load("@rules_cc//cc:action_names.bzl", "CPP_COMPILE_ACTION_NAME", "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME", "CPP_LINK_EXECUTABLE_ACTION_NAME", "CPP_LINK_STATIC_LIBRARY_ACTION_NAME", "C_COMPILE_ACTION_NAME", "STRIP_ACTION_NAME")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//private:beam_info.bzl", "OtpInfo", "erl_env_flags", "execution_erlexec", "execution_erlexec_file", "execution_erts_bin", "fips_erl_args", "otp_runtime_env", "otp_runtime_erl_args")
load("//private:otp_crypto_sdk.bzl", "crypto_sdk_info")
load("//private:runtime_archive_info.bzl", "BeamRuntimeSourceInfo")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[N,S|R]=A,{ok,artifact_normalizer,NB}=compile:file(N,[binary,report_errors,report_warnings]),{module,artifact_normalizer}=code:load_binary(artifact_normalizer,N,NB),C=compile:file(S,[binary,report_errors,report_warnings]),M=element(2,C),B=element(3,C),{module,M}=code:load_binary(M,S,B),M:main(R),halt()."
_OTP_BUILD_EXEC_GROUP = "otp_build"

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
        fail("otp_source_release requires non-empty srcs")
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
        fail("otp_source_release srcs must share one source root")
    return "/".join(common)

def _source_entries(files):
    root = _common_source_root(files)
    entries = []
    for file in files:
        relative = "." if file.short_path == root else file.short_path[len(root) + 1:]
        entries.append("{{{}, {}}}".format(_erl_string(file.path), _erl_string(relative)))
    return entries

def _tool_path(feature_configuration, action_name):
    return cc_common.get_tool_for_action(
        action_name = action_name,
        feature_configuration = feature_configuration,
    )

def _path_directories(paths):
    result = []
    for path in paths:
        if type(path) == "File":
            directory = path.path if path.is_directory else path.dirname
        else:
            directory = "/".join(path.rsplit("/", 1)[:-1])
        if directory and directory not in result:
            result.append(directory)
    return result

def _term_list(values):
    return "[{}]".format(", ".join([_erl_string(value) for value in values]))

def _cc_toolchain(ctx):
    toolchain = ctx.exec_groups[_OTP_BUILD_EXEC_GROUP].toolchains[CC_TOOLCHAIN_TYPE]
    if hasattr(toolchain, "cc_provider_in_toolchain") and hasattr(toolchain, "cc"):
        return toolchain.cc
    return toolchain

def _merge_environment(base, fragments):
    result = dict(base)
    for fragment in fragments:
        for key, value in fragment.items():
            if key in result and result[key] != value:
                fail("C/C++ toolchain action environments disagree on {}: '{}' versus '{}'".format(key, result[key], value))
            result[key] = value
    return result

def _execution_requirements(feature_configuration, action_names):
    result = {"block-network": "1"}
    for action_name in action_names:
        for requirement in cc_common.get_execution_requirements(
            action_name = action_name,
            feature_configuration = feature_configuration,
        ):
            if requirement == "block-network":
                continue
            result[requirement] = ""
    return result

def _validate_configure_options(options):
    owned = [
        "--disable-dynamic-ssl-lib",
        "--disable-fips",
        "--disable-jit",
        "--disable-static-nifs",
        "--enable-dynamic-ssl-lib",
        "--enable-fips",
        "--enable-jit",
        "--enable-static-nifs",
        "--with-ssl",
        "--without-ssl",
    ]
    for option in options:
        name = option.split("=", 1)[0]
        if name.startswith("--prefix") or name in owned:
            fail("otp_source_release owns prefix, JIT, and crypto configure policy; remove '{}'".format(option))

def _validate_make_options(options):
    owned_variables = [
        "AR",
        "ARFLAGS",
        "BINDIR",
        "CC",
        "CFLAGS",
        "CXX",
        "CXXFLAGS",
        "DED_LD",
        "DED_LD_FLAG_RUNTIME_LIBRARY_PATH",
        "DED_LIBS",
        "DED_LDFLAGS",
        "DED_LDFLAGS_CONFTEST",
        "DESTDIR",
        "ERLC_EMULATOR",
        "ERL_COMPILER_OPTIONS",
        "ERL_DETERMINISTIC",
        "LD",
        "LDEXECUTABLE",
        "LDFLAGS",
        "LDSHARED",
        "LIBS",
        "GNUMAKEFLAGS",
        "MAKEFLAGS",
        "MFLAGS",
        "NM",
        "OBJCOPY",
        "PATH",
        "PERL",
        "SHELL",
        "STRIP",
    ]
    forbidden_options = ["-C", "--directory", "-e", "--environment-overrides", "-f", "--file", "-I", "--include-dir", "--eval", "-j", "--jobs"]
    attached_short_options = ["-C", "-f", "-I", "-j"]
    for option in options:
        assignment = option.split("=", 1)[0]
        if assignment in owned_variables:
            fail("make_options may not override rule-owned variable '{}'".format(assignment))
        if any([option == flag or option.startswith(flag + "=") for flag in forbidden_options]) or any([option.startswith(flag) for flag in attached_short_options]):
            fail("make_options may not override Make execution policy with '{}'".format(option))

def _compile_configuration(cc_toolchain, feature_configuration, action_name, user_flags, add_legacy_cxx_options = False):
    variables = cc_common.create_compile_variables(
        add_legacy_cxx_options = add_legacy_cxx_options,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
    )
    flags = cc_common.get_memory_inefficient_command_line(
        action_name = action_name,
        feature_configuration = feature_configuration,
        variables = variables,
    )
    return struct(
        environment = cc_common.get_environment_variables(
            action_name = action_name,
            feature_configuration = feature_configuration,
            variables = variables,
        ),
        flags = flags + user_flags,
    )

def _link_configuration(cc_toolchain, feature_configuration, action_name, dynamic, user_flags):
    variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_linking_dynamic_library = dynamic,
        is_using_linker = True,
        must_keep_debug = False,
    )
    flags = cc_common.get_memory_inefficient_command_line(
        action_name = action_name,
        feature_configuration = feature_configuration,
        variables = variables,
    )
    return struct(
        environment = cc_common.get_environment_variables(
            action_name = action_name,
            feature_configuration = feature_configuration,
            variables = variables,
        ),
        flags = flags + user_flags,
    )

def _dynamic_runtime_library_path_flag(cc_toolchain, feature_configuration):
    marker = "__rules_elixir_mix_runtime_library_directory__"
    variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_linking_dynamic_library = True,
        is_using_linker = True,
        must_keep_debug = False,
        runtime_library_search_directories = depset([marker]),
    )
    flags = cc_common.get_memory_inefficient_command_line(
        action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
        feature_configuration = feature_configuration,
        variables = variables,
    )
    matches = []
    for index in range(len(flags)):
        flag = flags[index]
        if marker in flag:
            prefix = flag.replace(marker, "")
            if not prefix and index > 0:
                prefix = flags[index - 1] + " "
            if prefix and prefix not in matches:
                matches.append(prefix)
    if len(matches) > 1:
        fail("C/C++ toolchain exposes ambiguous dynamic runtime-library path flags: {}".format(matches))
    return matches[0] if matches else ""

def _archive_configuration(cc_toolchain, feature_configuration):
    output_marker = "__rules_elixir_mix_archive_output__"
    variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_using_linker = False,
        output_file = output_marker,
    )
    return struct(
        environment = cc_common.get_environment_variables(
            action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = variables,
        ),
        flags = _action_flags_without_io(cc_common.get_memory_inefficient_command_line(
            action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = variables,
        ), [output_marker]),
    )

def _strip_configuration(cc_toolchain, feature_configuration):
    variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
    )
    return struct(
        environment = cc_common.get_environment_variables(
            action_name = STRIP_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = variables,
        ),
    )

def _action_flags_without_io(flags, markers):
    result = []
    io_option_names = ["-o", "--input", "--output"]
    for flag in flags:
        if any([marker in flag for marker in markers]):
            if result and result[-1] in io_option_names:
                result.pop()
            continue
        result.append(flag)
    return result

def _partition_link_flags(flags):
    """Separate pre-object linker options from ordered post-object libraries."""
    options = []
    libraries = []
    state_group = []
    for flag in flags:
        if state_group:
            state_group.append(flag)
            if "--pop-state" in flag or "--end-group" in flag:
                libraries.extend(state_group)
                state_group = []
        elif "--push-state" in flag or "--start-group" in flag:
            state_group = [flag]
        elif (flag.startswith("-l") and len(flag) > 2) or flag.endswith(".a") or flag.endswith(".so"):
            libraries.append(flag)
        else:
            options.append(flag)
    if state_group:
        libraries.extend(state_group)
    return options, libraries

def _partition_driver_flags(flags):
    """Move compiler-driver mode selection from Autoconf flag variables."""
    driver_flags = []
    other_flags = []
    for flag in flags:
        if flag.startswith("--driver-mode=") or flag.startswith("-stdlib="):
            driver_flags.append(flag)
        else:
            other_flags.append(flag)
    return driver_flags, other_flags

def _otp_source_release_impl(ctx):
    if ctx.attr.jobs < 1 or ctx.attr.jobs > 64:
        fail("otp_source_release jobs must be between 1 and 64")
    if ctx.attr.libc == "musl" and ctx.attr.target_arch == "amd64" and ctx.attr.jit != "disabled":
        fail(
            "x86-64 musl OTP source builds require jit='disabled'; " +
            "the non-JIT profile is independent of the host AT_MINSIGSTKSZ value",
        )
    crypto = crypto_sdk_info(ctx.attr.crypto_sdk)
    has_runtime_wrapper = bool(crypto and crypto.execution_wrapper and crypto.execution_exec_wrapper)
    if ctx.attr.otp_fully_static == has_runtime_wrapper:
        fail(
            "otp_source_release requires exactly one native runtime contract: " +
            "otp_fully_static=True or a crypto SDK with target and execution wrappers",
        )
    if ctx.attr.static_crypto_nif and not crypto:
        fail("static_crypto_nif requires a crypto sysroot")
    if ctx.attr.fips == "required":
        if int(ctx.attr.version.split(".")[0]) < 29:
            fail("FIPS-required statically linked crypto requires OTP 29 or newer")
        if not crypto:
            fail("FIPS-required OTP requires crypto_sdk")
        if not ctx.attr.static_crypto_nif:
            fail("FIPS-required OTP requires static_crypto_nif=True")
    cc_toolchain = _cc_toolchain(ctx)
    requested_features = ctx.features + (crypto.cc_features if crypto else [])
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = requested_features,
        unsupported_features = ctx.disabled_features,
    )
    compiler = _tool_path(feature_configuration, C_COMPILE_ACTION_NAME)
    cxx = _tool_path(feature_configuration, CPP_COMPILE_ACTION_NAME)
    linker = _tool_path(feature_configuration, CPP_LINK_EXECUTABLE_ACTION_NAME)
    dynamic_linker = _tool_path(feature_configuration, CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME)
    archiver = _tool_path(feature_configuration, CPP_LINK_STATIC_LIBRARY_ACTION_NAME)
    strip = _tool_path(feature_configuration, STRIP_ACTION_NAME)
    c_compile = _compile_configuration(
        cc_toolchain,
        feature_configuration,
        C_COMPILE_ACTION_NAME,
        ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts + ctx.attr.copts,
    )
    cxx_compile = _compile_configuration(
        cc_toolchain,
        feature_configuration,
        CPP_COMPILE_ACTION_NAME,
        ctx.fragments.cpp.copts + ctx.fragments.cpp.cxxopts + ctx.attr.cxxopts,
        add_legacy_cxx_options = True,
    )
    executable_link = _link_configuration(
        cc_toolchain,
        feature_configuration,
        CPP_LINK_EXECUTABLE_ACTION_NAME,
        False,
        ctx.fragments.cpp.linkopts + ctx.attr.linkopts,
    )
    dynamic_link = _link_configuration(
        cc_toolchain,
        feature_configuration,
        CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
        True,
        ctx.fragments.cpp.linkopts + ctx.attr.linkopts,
    )
    dynamic_runtime_library_path_flag = _dynamic_runtime_library_path_flag(cc_toolchain, feature_configuration)
    archive = _archive_configuration(cc_toolchain, feature_configuration)
    strip_configuration = _strip_configuration(cc_toolchain, feature_configuration)
    cflags = c_compile.flags
    cxx_driver_flags, cxxflags = _partition_driver_flags(cxx_compile.flags)
    executable_link_driver_flags, executable_link_flags = _partition_driver_flags(executable_link.flags)
    dynamic_link_driver_flags, dynamic_link_flags = _partition_driver_flags(dynamic_link.flags)
    if executable_link_driver_flags != cxx_driver_flags or dynamic_link_driver_flags != cxx_driver_flags:
        fail(
            "C/C++ toolchain must expose one consistent C++ driver policy for compile and link actions: " +
            "compile={}, executable link={}, dynamic link={}".format(
                cxx_driver_flags,
                executable_link_driver_flags,
                dynamic_link_driver_flags,
            ),
        )
    executable_ldflags, executable_libraries = _partition_link_flags(executable_link_flags)
    dynamic_ldflags, dynamic_libraries = _partition_link_flags(dynamic_link_flags)

    install = ctx.actions.declare_directory(ctx.label.name + "_runtime")
    erts_bin = ctx.actions.declare_directory(ctx.label.name + "_erts_bin")
    exec_erts_bin = ctx.actions.declare_directory(ctx.label.name + "_exec_erts_bin")
    erl = ctx.actions.declare_file(ctx.label.name + "_erl")
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")
    ctx.actions.write(version_file, ctx.attr.version + "\n")

    _validate_configure_options(ctx.attr.configure_options)
    configure_options = ((["--disable-jit"] if ctx.attr.jit == "disabled" else ["--enable-jit"]) if ctx.attr.jit != "auto" else []) + ctx.attr.configure_options
    if ctx.attr.cross_compile and not any([option.startswith("--host=") for option in configure_options]):
        fail("cross_compile=True requires an explicit --host=<target-triplet> configure option")
    _validate_make_options(ctx.attr.make_options)

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
        fail("otp_source_release requires a hermetic POSIX toolbox")
    posix_bin = posix_tool_executables[0].dirname
    tool_paths = [
        ctx.executable.bash,
        ctx.executable.make,
    ] + posix_tool_executables
    tool_paths.append(ctx.executable.perl)
    path_directories = _path_directories(tool_paths + [compiler, cxx, linker, dynamic_linker, archiver, strip])

    owned_environment = {
        "AR": "{path, " + _erl_string(archiver) + "}",
        "CC": "{path, " + _erl_string(compiler) + "}",
        "CP": "{path, " + _erl_string(posix_bin + "/cp") + "}",
        "CXX": "{path, " + _erl_string(cxx) + "}",
        "LD": "{path, " + _erl_string(linker) + "}",
        "LN": "{path, " + _erl_string(posix_bin + "/ln") + "}",
        "MKDIR": "{path, " + _erl_string(posix_bin + "/mkdir") + "}",
        "PATH": "{path_list, " + _term_list(path_directories) + "}",
        "RANLIB": "{path, " + _erl_string(archiver.removesuffix("/ar") + "/ranlib") + "}",
        "RM": "{path, " + _erl_string(posix_bin + "/rm") + "}",
        "SHELL": "{path, " + _erl_string(ctx.executable.bash.path) + "}",
        "CONFIG_SHELL": "{path, " + _erl_string(ctx.executable.bash.path) + "}",
        "STRIP": "{path, " + _erl_string(strip) + "}",
    }
    if cc_toolchain.nm_executable:
        owned_environment["NM"] = "{path, " + _erl_string(cc_toolchain.nm_executable) + "}"
    if cc_toolchain.objcopy_executable:
        owned_environment["OBJCOPY"] = "{path, " + _erl_string(cc_toolchain.objcopy_executable) + "}"
    owned_environment["PERL"] = "{path, " + _erl_string(ctx.executable.perl.path) + "}"
    cc_environment = _merge_environment(
        {},
        [
            c_compile.environment,
            cxx_compile.environment,
            executable_link.environment,
            dynamic_link.environment,
            archive.environment,
            strip_configuration.environment,
        ],
    )
    environment = _merge_environment(owned_environment, [{
        key: _erl_string(value)
        for key, value in cc_environment.items()
    }])
    environment_term = "#{{{}}}".format(", ".join([
        "{} => {}".format(_erl_string(key), environment[key])
        for key in sorted(environment.keys())
    ]))

    bootstrap = ctx.attr.bootstrap_otp[OtpInfo]
    bootstrap_launcher = execution_erlexec_file(bootstrap)
    bootstrap_environment = otp_runtime_env(bootstrap)
    bootstrap_environment["ERL_AFLAGS"] = erl_env_flags(
        otp_runtime_erl_args(bootstrap) +
        fips_erl_args(bootstrap, activate = False),
    )
    bootstrap_environment_term = "#{{{}}}".format(", ".join([
        "{} => {}".format(_erl_string(key), _erl_string(bootstrap_environment[key]))
        for key in sorted(bootstrap_environment.keys())
    ]))
    bootstrap_erts_bin = execution_erts_bin(bootstrap)
    config = ctx.actions.declare_file(ctx.label.name + "_build.config")
    config_content = "#{\n" + ",\n".join([
        "  bash => {}".format(_erl_string(ctx.executable.bash.path)),
        "  bootstrap_environment => {}".format(bootstrap_environment_term),
        "  bootstrap_erlexec => {}".format(_erl_string(bootstrap.erlexec.path)),
        "  bootstrap_erts_bin => {}".format(_erl_string(bootstrap_erts_bin)),
        "  bootstrap_launcher => {}".format(_erl_string(bootstrap_launcher.path)),
        "  bootstrap_root => {}".format(_erl_string(bootstrap.erlang_home)),
        "  cflags => {}".format(_term_list(cflags)),
        "  cxx_driver_flags => {}".format(_term_list(cxx_driver_flags)),
        "  arflags => {}".format(_term_list(archive.flags)),
        "  configure_options => {}".format(_term_list(configure_options)),
        "  crypto_activation_args => {}".format(_term_list(crypto.activation_args) if crypto else "[]"),
        "  crypto_activation_tool => {}".format(_erl_string(crypto.activation_exec_tool.executable.path) if crypto and crypto.activation_exec_tool else "none"),
        "  crypto_execution_wrapper => {}".format(_erl_string(crypto.execution_wrapper.executable.path) if crypto and crypto.execution_wrapper else "none"),
        "  crypto_execution_exec_wrapper => {}".format(_erl_string(crypto.execution_exec_wrapper.executable.path) if crypto and crypto.execution_exec_wrapper else "none"),
        "  crypto_linkopts => {}".format(_term_list(crypto.linkopts) if crypto else "[]"),
        "  crypto_build_elf_interpreter => {}".format(
            _erl_string(crypto.build_elf_interpreter) if crypto and crypto.build_elf_interpreter else "none",
        ),
        "  crypto_prepared_state => {}".format(_erl_string(crypto.prepared_state.path) if crypto and crypto.prepared_state else "none"),
        "  crypto_runtime_environment => {}".format("#{" + ", ".join([
            "{} => {}".format(_erl_string(key), _erl_string(crypto.runtime_environment[key]))
            for key in sorted(crypto.runtime_environment.keys())
        ]) + "}" if crypto else "#{}"),
        "  crypto_sdk => {}".format(_erl_string(crypto.sysroot.path) if crypto else "none"),
        "  cxxflags => {}".format(_term_list(cxxflags)),
        "  cross_compiling => {}".format("true" if ctx.attr.cross_compile else "false"),
        "  environment => {}".format(environment_term),
        "  erl_output => {}".format(_erl_string(erl.path)),
        "  erts_bin_output => {}".format(_erl_string(erts_bin.path)),
        "  exec_erts_bin_output => {}".format(_erl_string(exec_erts_bin.path)),
        "  fips_required => {}".format("true" if ctx.attr.fips == "required" else "false"),
        "  jobs => {}".format(ctx.attr.jobs),
        "  jit => {}".format(_erl_string(ctx.attr.jit)),
        "  ded_ld => {}".format(_erl_string(dynamic_linker)),
        "  ded_ld_driver_flags => {}".format(_term_list(dynamic_link_driver_flags)),
        "  ded_ldflags => {}".format(_term_list(dynamic_ldflags)),
        "  ded_libs => {}".format(_term_list(dynamic_libraries)),
        "  ded_ld_runtime_library_path => {}".format(_erl_string(dynamic_runtime_library_path_flag)),
        "  ldflags => {}".format(_term_list(executable_ldflags)),
        "  ld_driver_flags => {}".format(_term_list(executable_link_driver_flags)),
        "  libraries => {}".format(_term_list(executable_libraries)),
        "  make => {}".format(_erl_string(ctx.executable.make.path)),
        "  make_options => {}".format(_term_list(ctx.attr.make_options)),
        "  native_fully_static => {}".format("true" if ctx.attr.otp_fully_static else "false"),
        "  output => {}".format(_erl_string(install.path)),
        "  perl => {}".format(_erl_string(ctx.executable.perl.path)),
        "  escript => {}".format(_erl_string(bootstrap_erts_bin + "/escript")),
        "  static_crypto_nif => {}".format("true" if ctx.attr.static_crypto_nif else "false"),
        "  source_directories => {}".format(_erl_string(ctx.file.source_directories.path)),
        "  sources => [{}]".format(",\n    ".join(_source_entries(ctx.files.srcs))),
        "  version => {}".format(_erl_string(ctx.attr.version)),
    ]) + "\n}.\n"
    ctx.actions.write(config, config_content)

    args = ctx.actions.args()
    args.add_all([
        "-noshell",
        "-eval",
        _DRIVER_EVAL,
        "-extra",
        ctx.file._normalizer,
        ctx.file._driver,
        config,
    ])
    direct_inputs = ctx.files.srcs + tool_files + [ctx.file._driver, ctx.file._normalizer, ctx.file.source_directories, config]
    crypto_inputs = depset(
        direct = [crypto.sysroot] + ([crypto.prepared_state] if crypto.prepared_state else []),
        transitive = [crypto.exec_files, crypto.files],
    ) if crypto else depset()

    action_env = otp_runtime_env(bootstrap)
    action_env.update({
        "HOME": install.path + ".work/bootstrap_home",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = execution_erlexec(bootstrap),
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [bootstrap.runtime_files, cc_toolchain.all_files, crypto_inputs],
        ),
        tools = [bootstrap_launcher, ctx.attr.bash[DefaultInfo].files_to_run, ctx.attr.make[DefaultInfo].files_to_run, ctx.attr.perl[DefaultInfo].files_to_run] + posix_tools + ([crypto.activation_exec_tool] if crypto and crypto.activation_exec_tool else []),
        outputs = [install, erts_bin, exec_erts_bin, erl],
        env = action_env,
        execution_requirements = _execution_requirements(feature_configuration, [
            C_COMPILE_ACTION_NAME,
            CPP_COMPILE_ACTION_NAME,
            CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
            CPP_LINK_EXECUTABLE_ACTION_NAME,
            CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
            STRIP_ACTION_NAME,
        ]),
        mnemonic = "OTPBUILD",
        progress_message = "Building Erlang/OTP {} from source".format(ctx.attr.version),
        exec_group = _OTP_BUILD_EXEC_GROUP,
        use_default_shell_env = False,
    )

    runtime_files = depset(
        direct = [install, erts_bin, exec_erts_bin, erl, version_file],
        transitive = [crypto.exec_files] if crypto else [],
    )
    erlang_home = install.path + "/lib/erlang"
    erlang_home_short_path = install.short_path + "/lib/erlang"
    return [
        DefaultInfo(files = runtime_files),
        BeamRuntimeSourceInfo(
            kind = "otp",
            root = install,
            root_relative_path = "lib/erlang",
            version = ctx.attr.version,
        ),
        OtpInfo(
            version = ctx.attr.version,
            boot_file = None,
            boot_file_short_path = "",
            crypto_sdk = crypto,
            erlang_home = erlang_home,
            erlang_home_short_path = erlang_home_short_path,
            erl = erl,
            erlexec = erl,
            erts_bin = erts_bin.path,
            erts_bin_short_path = erts_bin.short_path,
            exec_erts_bin = exec_erts_bin.path,
            exec_erts_bin_short_path = exec_erts_bin.short_path,
            fips = ctx.attr.fips,
            fully_static = ctx.attr.otp_fully_static,
            jit = ctx.attr.jit,
            runtime_wrapped = has_runtime_wrapper,
            runtime_files = runtime_files,
            static_crypto_nif = ctx.attr.static_crypto_nif,
            version_file = version_file,
        ),
    ]

otp_source_release = rule(
    implementation = _otp_source_release_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "srcs": attr.label_list(mandatory = True, allow_files = True),
        "bootstrap_otp": attr.label(mandatory = True, providers = [OtpInfo], cfg = config.exec(_OTP_BUILD_EXEC_GROUP)),
        "bash": attr.label(mandatory = True, executable = True, allow_files = True, cfg = config.exec(_OTP_BUILD_EXEC_GROUP)),
        "make": attr.label(mandatory = True, executable = True, allow_files = True, cfg = config.exec(_OTP_BUILD_EXEC_GROUP)),
        "posix_tools": attr.label_list(mandatory = True, allow_files = True, cfg = config.exec(_OTP_BUILD_EXEC_GROUP)),
        "perl": attr.label(mandatory = True, executable = True, allow_files = True, cfg = config.exec(_OTP_BUILD_EXEC_GROUP)),
        "crypto_sdk": attr.label(allow_files = True),
        "cross_compile": attr.bool(default = False),
        "fips": attr.string(default = "disabled", values = ["disabled", "required"]),
        "configure_options": attr.string_list(),
        "make_options": attr.string_list(),
        "otp_fully_static": attr.bool(default = False),
        "copts": attr.string_list(),
        "cxxopts": attr.string_list(),
        "linkopts": attr.string_list(),
        "static_crypto_nif": attr.bool(default = False),
        "source_directories": attr.label(mandatory = True, allow_single_file = True),
        "jobs": attr.int(default = 8),
        "jit": attr.string(default = "auto", values = ["auto", "disabled", "required"]),
        "libc": attr.string(mandatory = True, values = ["glibc", "musl"]),
        "target_arch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "_driver": attr.label(
            default = Label("//private:otp_build_driver.erl"),
            allow_single_file = [".erl"],
        ),
        "_normalizer": attr.label(
            default = Label("//private:artifact_normalizer.erl"),
            allow_single_file = [".erl"],
        ),
    },
    fragments = ["cpp"],
    exec_groups = {
        _OTP_BUILD_EXEC_GROUP: exec_group(toolchains = use_cc_toolchain()),
    },
)
