"""Hermetic OTP source build using explicit tools and an Erlang driver."""

load("@rules_cc//cc:action_names.bzl", "CPP_COMPILE_ACTION_NAME", "CPP_LINK_EXECUTABLE_ACTION_NAME", "CPP_LINK_STATIC_LIBRARY_ACTION_NAME", "C_COMPILE_ACTION_NAME", "STRIP_ACTION_NAME")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//private:beam_info.bzl", "OtpInfo", "otp_runtime_env")
load("//private:otp_crypto_sdk.bzl", "crypto_sdk_info")

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

def _dedupe(values):
    result = []
    for value in values:
        if value not in result:
            result.append(value)
    return result

def _validate_configure_options(options):
    owned = [
        "--disable-dynamic-ssl-lib",
        "--disable-fips",
        "--disable-static-nifs",
        "--enable-dynamic-ssl-lib",
        "--enable-fips",
        "--enable-static-nifs",
        "--with-ssl",
        "--without-ssl",
    ]
    for option in options:
        name = option.split("=", 1)[0]
        if name.startswith("--prefix") or name in owned:
            fail("otp_source_release owns prefix and crypto configure policy; remove '{}'".format(option))

def _validate_make_options(options):
    owned_variables = [
        "AR",
        "BINDIR",
        "CC",
        "CFLAGS",
        "CXX",
        "CXXFLAGS",
        "DESTDIR",
        "ERLC_EMULATOR",
        "ERL_COMPILER_OPTIONS",
        "ERL_DETERMINISTIC",
        "LD",
        "LDFLAGS",
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

def _compile_flags(cc_toolchain, feature_configuration, action_name, user_flags, add_legacy_cxx_options = False):
    flags = cc_common.get_memory_inefficient_command_line(
        action_name = action_name,
        feature_configuration = feature_configuration,
        variables = cc_common.create_compile_variables(
            add_legacy_cxx_options = add_legacy_cxx_options,
            cc_toolchain = cc_toolchain,
            feature_configuration = feature_configuration,
        ),
    )
    return _dedupe(flags + user_flags)

def _link_flags(cc_toolchain, feature_configuration, user_flags):
    flags = cc_common.get_memory_inefficient_command_line(
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
        feature_configuration = feature_configuration,
        variables = cc_common.create_link_variables(
            cc_toolchain = cc_toolchain,
            feature_configuration = feature_configuration,
            is_linking_dynamic_library = False,
            is_using_linker = True,
            must_keep_debug = False,
        ),
    )
    return _dedupe(flags + user_flags)

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

def _otp_source_release_impl(ctx):
    if ctx.attr.jobs < 1 or ctx.attr.jobs > 64:
        fail("otp_source_release jobs must be between 1 and 64")
    crypto = crypto_sdk_info(ctx.attr.crypto_sdk)
    if ctx.attr.static_crypto_nif and not crypto:
        fail("static_crypto_nif requires a crypto sysroot")
    if ctx.attr.fips == "required":
        if int(ctx.attr.version.split(".")[0]) < 29:
            fail("FIPS-required statically linked crypto requires OTP 29 or newer")
        if not crypto:
            fail("FIPS-required OTP requires crypto_sdk")
        if not ctx.attr.static_crypto_nif:
            fail("FIPS-required OTP requires static_crypto_nif=True")
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compiler = _tool_path(feature_configuration, C_COMPILE_ACTION_NAME)
    cxx = _tool_path(feature_configuration, CPP_COMPILE_ACTION_NAME)
    linker = _tool_path(feature_configuration, CPP_LINK_EXECUTABLE_ACTION_NAME)
    archiver = _tool_path(feature_configuration, CPP_LINK_STATIC_LIBRARY_ACTION_NAME)
    strip = _tool_path(feature_configuration, STRIP_ACTION_NAME)
    cflags = _compile_flags(
        cc_toolchain,
        feature_configuration,
        C_COMPILE_ACTION_NAME,
        ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts + ctx.attr.copts,
    )
    cxxflags = _compile_flags(
        cc_toolchain,
        feature_configuration,
        CPP_COMPILE_ACTION_NAME,
        ctx.fragments.cpp.copts + ctx.fragments.cpp.cxxopts + ctx.attr.cxxopts,
        add_legacy_cxx_options = True,
    )
    ldflags, libraries = _partition_link_flags(_link_flags(
        cc_toolchain,
        feature_configuration,
        ctx.fragments.cpp.linkopts + ctx.attr.linkopts,
    ))

    install = ctx.actions.declare_directory(ctx.label.name + "_runtime")
    erts_bin = ctx.actions.declare_directory(ctx.label.name + "_erts_bin")
    erl = ctx.actions.declare_file(ctx.label.name + "_erl")
    version_file = ctx.actions.declare_file(ctx.label.name + "_version")
    ctx.actions.write(version_file, ctx.attr.version + "\n")

    configure_options = ctx.attr.configure_options
    _validate_configure_options(configure_options)
    _validate_make_options(ctx.attr.make_options)

    tool_files = ctx.files.posix_tools
    tool_paths = [
        ctx.executable.bash,
        ctx.executable.make,
    ] + tool_files
    tool_paths.append(ctx.executable.perl)
    path_directories = _path_directories(tool_paths + [compiler, cxx, linker, archiver, strip])

    environment = {
        "AR": "{path, " + _erl_string(archiver) + "}",
        "CC": "{path, " + _erl_string(compiler) + "}",
        "CXX": "{path, " + _erl_string(cxx) + "}",
        "LD": "{path, " + _erl_string(cc_toolchain.ld_executable) + "}",
        "PATH": "{path_list, " + _term_list(path_directories) + "}",
        "SHELL": "{path, " + _erl_string(ctx.executable.bash.path) + "}",
        "CONFIG_SHELL": "{path, " + _erl_string(ctx.executable.bash.path) + "}",
        "STRIP": "{path, " + _erl_string(strip) + "}",
    }
    if cc_toolchain.nm_executable:
        environment["NM"] = "{path, " + _erl_string(cc_toolchain.nm_executable) + "}"
    if cc_toolchain.objcopy_executable:
        environment["OBJCOPY"] = "{path, " + _erl_string(cc_toolchain.objcopy_executable) + "}"
    environment["PERL"] = "{path, " + _erl_string(ctx.executable.perl.path) + "}"
    environment_term = "#{{{}}}".format(", ".join([
        "{} => {}".format(_erl_string(key), environment[key])
        for key in sorted(environment.keys())
    ]))

    bootstrap = ctx.attr.bootstrap_otp[OtpInfo]
    config = ctx.actions.declare_file(ctx.label.name + "_build.config")
    config_content = "#{\n" + ",\n".join([
        "  bash => {}".format(_erl_string(ctx.executable.bash.path)),
        "  bootstrap_erlexec => {}".format(_erl_string(bootstrap.erlexec.path)),
        "  bootstrap_erts_bin => {}".format(_erl_string(bootstrap.erts_bin)),
        "  bootstrap_root => {}".format(_erl_string(bootstrap.erlang_home)),
        "  cflags => {}".format(_term_list(cflags)),
        "  configure_options => {}".format(_term_list(configure_options)),
        "  crypto_activation_args => {}".format(_term_list(crypto.activation_args) if crypto else "[]"),
        "  crypto_activation_tool => {}".format(_erl_string(crypto.activation_exec_tool.executable.path) if crypto and crypto.activation_exec_tool else "none"),
        "  crypto_linkopts => {}".format(_term_list(crypto.linkopts) if crypto else "[]"),
        "  crypto_runtime_environment => {}".format("#{" + ", ".join([
            "{} => {}".format(_erl_string(key), _erl_string(crypto.runtime_environment[key]))
            for key in sorted(crypto.runtime_environment.keys())
        ]) + "}" if crypto else "#{}"),
        "  crypto_sdk => {}".format(_erl_string(crypto.sysroot.path) if crypto else "none"),
        "  cxxflags => {}".format(_term_list(cxxflags)),
        "  environment => {}".format(environment_term),
        "  erl_output => {}".format(_erl_string(erl.path)),
        "  erts_bin_output => {}".format(_erl_string(erts_bin.path)),
        "  fips_required => {}".format("true" if ctx.attr.fips == "required" else "false"),
        "  jobs => {}".format(ctx.attr.jobs),
        "  ldflags => {}".format(_term_list(ldflags)),
        "  libraries => {}".format(_term_list(libraries)),
        "  make => {}".format(_erl_string(ctx.executable.make.path)),
        "  make_options => {}".format(_term_list(ctx.attr.make_options)),
        "  output => {}".format(_erl_string(install.path)),
        "  perl => {}".format(_erl_string(ctx.executable.perl.path)),
        "  escript => {}".format(_erl_string(bootstrap.erts_bin + "/escript")),
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
        direct = [crypto.sysroot],
        transitive = [crypto.exec_files],
    ) if crypto else depset()

    action_env = otp_runtime_env(bootstrap)
    action_env.update({
        "HOME": install.path + ".work/bootstrap_home",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = bootstrap.erlexec,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [bootstrap.runtime_files, cc_toolchain.all_files, crypto_inputs],
        ),
        tools = [ctx.attr.bash[DefaultInfo].files_to_run, ctx.attr.make[DefaultInfo].files_to_run, ctx.attr.perl[DefaultInfo].files_to_run] + ([crypto.activation_exec_tool] if crypto and crypto.activation_exec_tool else []),
        outputs = [install, erts_bin, erl],
        env = action_env,
        execution_requirements = {"block-network": "1"},
        mnemonic = "OTPBUILD",
        progress_message = "Building Erlang/OTP {} from source".format(ctx.attr.version),
        toolchain = "@rules_cc//cc:toolchain_type",
        use_default_shell_env = False,
    )

    runtime_files = depset(direct = [install, erts_bin, erl, version_file])
    erlang_home = install.path + "/lib/erlang"
    erlang_home_short_path = install.short_path + "/lib/erlang"
    return [
        DefaultInfo(files = runtime_files),
        OtpInfo(
            version = ctx.attr.version,
            crypto_sdk = crypto,
            erlang_home = erlang_home,
            erlang_home_short_path = erlang_home_short_path,
            erl = erl,
            erlexec = erl,
            erts_bin = erts_bin.path,
            erts_bin_short_path = erts_bin.short_path,
            fips = ctx.attr.fips,
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
        "bootstrap_otp": attr.label(mandatory = True, providers = [OtpInfo], cfg = "exec"),
        "bash": attr.label(mandatory = True, executable = True, allow_files = True, cfg = "exec"),
        "make": attr.label(mandatory = True, executable = True, allow_files = True, cfg = "exec"),
        "posix_tools": attr.label_list(mandatory = True, allow_files = True, cfg = "exec"),
        "perl": attr.label(mandatory = True, executable = True, allow_files = True, cfg = "exec"),
        "crypto_sdk": attr.label(allow_files = True),
        "fips": attr.string(default = "disabled", values = ["disabled", "required"]),
        "configure_options": attr.string_list(),
        "make_options": attr.string_list(),
        "copts": attr.string_list(),
        "cxxopts": attr.string_list(),
        "linkopts": attr.string_list(),
        "static_crypto_nif": attr.bool(default = False),
        "source_directories": attr.label(mandatory = True, allow_single_file = True),
        "jobs": attr.int(default = 8),
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
    toolchains = use_cc_toolchain(),
)
