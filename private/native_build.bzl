"""Selective hermetic C/C++ and POSIX closure for native Mix compilers."""

load("@rules_cc//cc:action_names.bzl", "CPP_COMPILE_ACTION_NAME", "CPP_LINK_EXECUTABLE_ACTION_NAME", "CPP_LINK_STATIC_LIBRARY_ACTION_NAME", "C_COMPILE_ACTION_NAME", "STRIP_ACTION_NAME")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

_EXECUTION_ROOT_MARKER = "/proc/self/cwd/"

def use_native_cc_toolchain():
    """Return the standard C/C++ toolchain requirement for a native action."""
    return use_cc_toolchain()

def _dedupe(values):
    result = []
    for value in values:
        if value not in result:
            result.append(value)
    return result

def _execution_root_path(path):
    return path if path.startswith("/") else _EXECUTION_ROOT_MARKER + path

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
            directory = path.rsplit("/", 1)[0] if "/" in path else ""
        if directory and directory not in result:
            result.append(_execution_root_path(directory))
    return result

def _compile_flags(ctx, cc_toolchain, feature_configuration, action_name, add_legacy_cxx_options = False):
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
    if action_name == C_COMPILE_ACTION_NAME:
        flags = flags + ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts + ctx.attr.native_copts
    else:
        flags = flags + ctx.fragments.cpp.copts + ctx.fragments.cpp.cxxopts + ctx.attr.native_cxxopts
    return _dedupe(flags)

def _link_flags(ctx, cc_toolchain, feature_configuration):
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
    return _dedupe(flags + ctx.fragments.cpp.linkopts + ctx.attr.native_linkopts)

def _rewrite_path_token(token):
    if not token or token.startswith("/") or token.startswith("-"):
        return token
    return _execution_root_path(token)

def _rewrite_flags(flags):
    """Make execroot-relative toolchain paths survive Mix's project chdir."""
    result = []
    path_follows = False
    joined_prefixes = ["-I", "-L", "-B", "-isystem", "-iquote", "-idirafter"]
    assignment_prefixes = ["--sysroot=", "--gcc-toolchain="]
    for flag in flags:
        if path_follows:
            result.append(_rewrite_path_token(flag))
            path_follows = False
            continue
        if flag in joined_prefixes:
            result.append(flag)
            path_follows = True
            continue
        rewritten = None
        for prefix in assignment_prefixes:
            if flag.startswith(prefix):
                rewritten = prefix + _rewrite_path_token(flag[len(prefix):])
                break
        if rewritten == None:
            for prefix in joined_prefixes:
                if flag.startswith(prefix) and len(flag) > len(prefix):
                    rewritten = prefix + _rewrite_path_token(flag[len(prefix):])
                    break
        result.append(rewritten if rewritten != None else flag)
    return result

def _shell_quote(value):
    if not value:
        return "''"
    safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
    if all([value[index] in safe for index in range(len(value))]):
        return value
    return "'{}'".format(value.replace("'", "'\"'\"'"))

def _flags_environment(flags):
    return " ".join([_shell_quote(flag) for flag in _rewrite_flags(flags)])

def native_build_context(ctx):
    """Resolve native inputs, tools, and strict environment for one Mix action.

    Args:
      ctx: Native Mix compile rule context.

    Returns:
      A struct containing the action environment, inputs, and tools.
    """
    beam_toolchain = ctx.toolchains["//:toolchain_type"]
    native = beam_toolchain.native_build_tools
    if native == None:
        fail("{} requests native_build=True, but the selected Elixir toolchain has no declared native Bash/Make/Perl/POSIX closure".format(ctx.label))

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
    path_files = native.path_files.to_list()
    path_directories = _path_directories([
        native.bash.executable,
        native.make.executable,
        native.perl.executable,
    ] + path_files + [compiler, cxx, linker, archiver, strip])

    environment = {
        "AR": _execution_root_path(archiver),
        "CC": _execution_root_path(compiler),
        "CFLAGS": _flags_environment(_compile_flags(ctx, cc_toolchain, feature_configuration, C_COMPILE_ACTION_NAME)),
        "CONFIG_SHELL": _execution_root_path(native.bash.executable.path),
        "CXX": _execution_root_path(cxx),
        "CXXFLAGS": _flags_environment(_compile_flags(ctx, cc_toolchain, feature_configuration, CPP_COMPILE_ACTION_NAME, add_legacy_cxx_options = True)),
        "LD": _execution_root_path(cc_toolchain.ld_executable),
        "LDFLAGS": _flags_environment(_link_flags(ctx, cc_toolchain, feature_configuration)),
        "MAKE": _execution_root_path(native.make.executable.path),
        "MAKEFLAGS": "-j{}".format(ctx.attr.native_make_jobs),
        "PATH": ":".join([beam_toolchain.otpinfo.erts_bin] + path_directories),
        "PERL": _execution_root_path(native.perl.executable.path),
        "SHELL": _execution_root_path(native.bash.executable.path),
        "STRIP": _execution_root_path(strip),
    }
    if cc_toolchain.nm_executable:
        environment["NM"] = _execution_root_path(cc_toolchain.nm_executable)
    if cc_toolchain.objcopy_executable:
        environment["OBJCOPY"] = _execution_root_path(cc_toolchain.objcopy_executable)

    return struct(
        environment = environment,
        inputs = depset(transitive = [native.files, cc_toolchain.all_files]),
        tools = native.tools,
    )
