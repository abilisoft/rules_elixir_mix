"""Minimal BEAM providers shared by the Mix rules."""

ErlangAppInfo = provider(
    doc = "A Mix-compiled BEAM/OTP application.",
    fields = {
        "app_name": "OTP application name.",
        "beam": "Declared Mix build-root tree artifacts.",
        "build_roots": "Action-time Mix build-root paths.",
        "build_roots_short_path": "Runfiles-relative Mix build-root paths.",
        "compile_deps": "Depset of applications needed while compiling this application.",
        "compile_fingerprint": "Declared file fingerprinting the compiled application artifact.",
        "lib_dirs": "Action-time ERL_LIBS directories.",
        "lib_dirs_short_path": "Runfiles-relative ERL_LIBS directories.",
        "deps": "Compatibility alias for the transitive runtime dependency depset.",
        "direct_compile_deps": "Direct compile-only application dependencies.",
        "direct_deps": "Compatibility alias for direct runtime dependencies.",
        "direct_runtime_deps": "Direct runtime application dependencies.",
        "direct_type_deps": "Direct compile-only applications whose types are referenced by this application.",
        "extra_apps": "Additional OTP runtime applications.",
        "include": "Public Erlang header files.",
        "license_files": "License files propagated with the application.",
        "priv": "Runtime files under the application's priv directory.",
        "project_files": "Declared source-project files for writable local dependency staging.",
        "project_entries": "Stable logical source-project mappings for writable local dependency staging.",
        "project_fingerprint": "Declared source-project fingerprint, or None when no project is staged.",
        "project_root_short_path": "Runfiles-relative source-project root, or an empty string.",
        "runtime_deps": "Depset of transitive runtime application dependencies.",
        "type_deps": "Depset of applications needed to analyze this application's types.",
        "srcs": "Declared source files.",
    },
)

OtpInfo = provider(
    doc = "An Erlang/OTP runtime consumed by an Elixir toolchain.",
    fields = {
        "version": "OTP version.",
        "boot_file": "Optional declared .boot file used before installed bin/start.boot exists.",
        "boot_file_short_path": "Runfiles-relative path of the optional declared .boot file.",
        "erlang_home": "Action-time OTP root containing bin/ and lib/.",
        "erlang_home_short_path": "Runfiles-relative OTP root.",
        "erl": "Compatibility alias for the declared erlexec executable.",
        "erlexec": "Declared native erlexec executable; never the bin/erl shell script.",
        "erts_bin": "Action-time ERTS directory containing beam.smp and erlexec.",
        "erts_bin_short_path": "Runfiles-relative ERTS directory.",
        "exec_erts_bin": "Execution-configured ERTS launcher directory.",
        "exec_erts_bin_short_path": "Runfiles-relative execution-configured ERTS launcher directory.",
        "crypto_sdk": "Normalized OtpCryptoSdkInfo, or None.",
        "fips": "FIPS policy: disabled or required.",
        "fully_static": "Whether every native OTP executable is statically linked.",
        "jit": "Runtime emulator policy: auto, disabled, or required.",
        "runtime_wrapped": "Whether every dynamic native executable has an adjacent declared static wrapper.",
        "version_file": "Declared version file used for cache invalidation.",
        "runtime_files": "Depset containing the OTP runtime inputs.",
        "static_crypto_nif": "Whether crypto is statically embedded into beam.smp.",
    },
)

OtpCryptoSdkInfo = provider(
    doc = "Backend-neutral crypto SDK consumed by an OTP build.",
    fields = {
        "activation_args": "Direct argument vector for the optional activation executable.",
        "activation_exec_tool": "Execution-configured FilesToRunProvider used by build actions, or None.",
        "activation_tool": "FilesToRunProvider for activation, or None.",
        "activation_tool_release_path": "Activation executable path relative to the staged release SDK.",
        "backend_metadata": "Opaque producer metadata; rules_elixir_mix never interprets it.",
        "cc_features": "C/C++ toolchain features required while building OTP against this SDK.",
        "exec_files": "Execution-configured tools and support files used only by build actions.",
        "exec_support_files": "Additional execution-only files required by opaque SDK tools.",
        "build_elf_interpreter": "Fail-closed linker marker emitted before the source driver binds the declared SDK loader.",
        "execution_exec_wrapper": "Execution-configured shell-free runtime wrapper, or None.",
        "execution_wrapper": "Target-configured shell-free runtime wrapper, or None.",
        "execution_wrapper_environment": "Opaque environment templates required by the runtime wrapper.",
        "execution_wrapper_release_path": "Runtime-wrapper path relative to the staged release SDK.",
        "files": "Target-configured SDK and deployment files.",
        "fully_static": "Whether the SDK has no provider runtime payload or activation step.",
        "linkopts": "Backend-neutral libraries/options appended through OTP's LIBS contract.",
        "prepared_state": "Execution-prepared provider state shared by BEAM actions, or None.",
        "runtime_entries": "Runtime files and their SDK-relative release destinations.",
        "runtime_environment": "Environment values with {sysroot}/{activation_root} placeholders.",
        "runtime_files": "Depset containing only the deployment runtime payload.",
        "sysroot": "Directory artifact containing include/ and lib/libcrypto.a.",
    },
)

_EXECUTION_ROOT_MARKER = "/proc/self/cwd/"
_RUNTIME_PATH_EVAL = """
{ok,Cwd}=file:get_cwd(),
Marker="/proc/self/"++"cwd/",
Resolve=fun(P)->
  case lists:prefix(Marker,P) of
    true->filename:join(Cwd,lists:nthtail(length(Marker),P));
    false->case filename:pathtype(P) of relative->filename:absname(P);_->P end
  end
end,
lists:foreach(fun(Entry)->
  {Key,Rest}=lists:splitwith(fun(Character)->Character=/=$= end,Entry),
  case Rest of
    [$=|Value]->
      Opaque=["RULES_ELIXIR_MIX_ESCRIPT_EMU_ARGS","RULES_ELIXIR_MIX_ESCRIPT_SHEBANG"],
      ResolvedValue=case lists:member(Key,Opaque) of
        true->Value;
        false->lists:flatten(string:replace(Value,Marker,Cwd++"/",all))
      end,
      case ResolvedValue=:=Value of
        true->ok;
        false->true=os:putenv(Key,ResolvedValue)
      end;
    _->ok
  end
end,os:getenv()),
PathKeys=["BINDIR","ERL_ROOTDIR","FIPS_MODULE_CONF","HEX_HOME","HOME","MIX_ARCHIVES","MIX_BUILD_PATH","MIX_BUILD_ROOT","MIX_DEPS_PATH","MIX_HOME","OPENSSL_CONF","OPENSSL_MODULES","REBAR_BASE_DIR","REBAR_CACHE_DIR","REBAR_CONFIG","REBAR_GLOBAL_CONFIG_DIR","ROOTDIR","RULES_ELIXIR_MIX_BUILD_CACHE_MANIFEST","RULES_ELIXIR_MIX_BUILD_MANIFEST","RULES_ELIXIR_MIX_BUILD_ROOT","RULES_ELIXIR_MIX_CRYPTO_STATE","RULES_ELIXIR_MIX_ERTS_PATH","RULES_ELIXIR_MIX_INCLUDE_MANIFEST","RULES_ELIXIR_MIX_OUTPUT","RULES_ELIXIR_MIX_PRIV_MANIFEST","RULES_ELIXIR_MIX_PROJECT_DIR","RULES_ELIXIR_MIX_PROJECT_MANIFEST","RULES_ELIXIR_MIX_DEPS_MANIFEST","RULES_ELIXIR_MIX_REBAR3","RULES_ELIXIR_MIX_REBAR_CONFIG","RULES_ELIXIR_MIX_RELEASE_ROOT","RULES_ELIXIR_MIX_FIPS_RELEASE_ROOT","RULES_ELIXIR_MIX_CRYPTO_ACTIVATION_CONFIG","RULES_ELIXIR_MIX_CRYPTO_LAUNCH_CONFIG","RULES_ELIXIR_MIX_CRYPTO_RELEASE_MANIFEST","RULES_ELIXIR_MIX_FIPS_RELEASE_ENFORCEMENT","TMPDIR"],
lists:foreach(fun(Key)->case os:getenv(Key) of false->ok;Value->true=os:putenv(Key,Resolve(Value)) end end,PathKeys),
case os:getenv("RULES_ELIXIR_MIX_ERTS_PATH") of false->ok;ErtsPath->true=os:putenv("PATH",ErtsPath) end,
lists:foreach(fun(Key)->case os:getenv(Key) of false->ok;Value->true=os:putenv(Key,string:join([Resolve(Path)||Path<-string:tokens(Value,":")],":")) end end,["ERL_LIBS","PATH"]),
true=code:set_path([Resolve(Path)||Path<-code:get_path()]),
ok.
"""

def execution_root_path(path):
    """Return an absolute-at-launch path without embedding Bazel's execroot."""
    if path.startswith("/"):
        return path
    return _EXECUTION_ROOT_MARKER + path

def runtime_path_erl_args():
    """Normalize exec/runfiles-relative paths before an Erlang action changes cwd."""
    return ["-eval", _RUNTIME_PATH_EVAL]

def otp_boot_erl_args(otp_info, runfiles = False):
    """Return a declared pre-install boot path without its .boot suffix.

    Args:
      otp_info: Selected OtpInfo provider.
      runfiles: Whether to use the runfiles-relative boot path.

    Returns:
      An Erlang -boot argument pair, or an empty list.
    """
    boot_file = getattr(otp_info, "boot_file", None)
    if not boot_file:
        return []
    path = otp_info.boot_file_short_path if runfiles else boot_file.path
    if not path.endswith(".boot"):
        fail("OtpInfo boot_file must end in .boot")
    return ["-boot", execution_root_path(path.removesuffix(".boot"))]

def otp_runtime_erl_args(otp_info, runfiles = False):
    """Return path normalization and optional pre-install boot arguments.

    Args:
      otp_info: Selected OtpInfo provider.
      runfiles: Whether to use runfiles-relative paths.

    Returns:
      Erlang arguments suitable for ERL_AFLAGS.
    """
    return runtime_path_erl_args() + otp_boot_erl_args(otp_info, runfiles = runfiles)

def _erl_env_arg(value):
    # erlexec's environment-flag parser does not interpret backslash escapes
    # inside quotes. Escape separators in the unquoted state so expressions may
    # safely contain both quote styles and newlines.
    escaped = []
    for index in range(len(value)):
        char = value[index]
        if char in [" ", "\t", "\n", "\r", "\f", "\v", "\\", '"', "'"]:
            escaped.append("\\")
        escaped.append(char)
    return "".join(escaped)

def erl_env_flags(args):
    """Encode an argv vector for ERL_AFLAGS without involving a shell."""
    return " ".join([_erl_env_arg(arg) for arg in args])

def path_join(*parts):
    """Join slash-separated Bazel paths without normalizing `..`.

    Args:
      *parts: Path components to join.

    Returns:
      A slash-separated path string.
    """
    result = ""
    for part in parts:
        if not part:
            continue
        result = part.rstrip("/") if not result else result.rstrip("/") + "/" + part.strip("/")
    return result

def fips_erl_args(otp_info, runfiles = False, activate = False):
    """Return the VM arguments that enable required FIPS mode before boot.

    Provider activation cannot happen inside this VM: provider-backed SDKs may
    initialize before an Erlang `-eval` runs. Callers
    prepare the SDK with `prepare_crypto_runtime` and inject its environment
    before starting erlexec.

    Args:
      otp_info: Selected OtpInfo provider.
      runfiles: Retained for call-site readability; the arguments contain no paths.
      activate: Must remain False. In-VM activation is intentionally rejected.

    Returns:
      Erlang command-line arguments for a FIPS-required runtime, or an empty list.
    """
    if activate:
        fail("crypto SDK activation must be prepared before the Erlang VM starts")
    if runfiles:
        return ["-crypto", "fips_mode", "true"] if otp_info.fips == "required" else []
    return ["-crypto", "fips_mode", "true"] if otp_info.fips == "required" else []

def prepare_crypto_runtime(_ctx, otp_info, _output_name, runfiles = False):
    """Use crypto SDK state prepared before an Erlang VM starts.

    The normalized SDK rule prepares provider state exactly once per Bazel
    configuration. Every consumer reuses that declared, cacheable artifact and
    renders the producer-defined environment before VM startup. Packaged
    releases remain responsible for their own per-deployment activation.

    Args:
      _ctx: Retained for call-site compatibility.
      otp_info: Selected OtpInfo provider.
      _output_name: Retained for call-site compatibility.
      runfiles: Whether returned environment paths target a runfiles tree.

    Returns:
      A struct with files and environment fields.
    """
    sdk = otp_info.crypto_sdk
    if not sdk or not sdk.prepared_state:
        return struct(environment = {}, files = depset())

    sysroot = sdk.sysroot.short_path if runfiles else sdk.sysroot.path
    activation_root = sdk.prepared_state.short_path if runfiles else sdk.prepared_state.path
    environment = {
        key: value.replace("{sysroot}", execution_root_path(sysroot)).replace("{activation_root}", execution_root_path(activation_root))
        for key, value in sdk.runtime_environment.items()
    }
    return struct(
        environment = environment,
        files = depset(
            direct = [sdk.prepared_state, sdk.sysroot],
        ),
    )

def crypto_runtime_files(otp_info):
    """Return crypto target and exec files needed by Bazel-run executables.

    Fully static SDKs deliberately contribute nothing: their sysroot is a
    build input, not release payload. Provider-backed SDKs need the normalized
    target-configured SDK closure because their early activation expression
    references both the sysroot and the activation executable through runfiles.
    """
    sdk = otp_info.crypto_sdk
    return depset(transitive = [sdk.files, sdk.exec_files]) if sdk and sdk.activation_tool else depset()

def otp_runtime_env(otp_info, runfiles = False, use_execution_overlay = True):
    """Return the environment required to invoke erlexec directly.

    Args:
      otp_info: Selected OtpInfo provider.
      runfiles: Whether paths must be runfiles-relative short paths.
      use_execution_overlay: Whether to select execution-configured ERTS launchers.

    Returns:
      A deterministic environment fragment for the native VM launcher.
    """
    root = otp_info.erlang_home_short_path if runfiles else otp_info.erlang_home
    sdk = getattr(otp_info, "crypto_sdk", None)
    bindir = execution_erts_bin(otp_info, runfiles = runfiles) if use_execution_overlay else (otp_info.erts_bin_short_path if runfiles else otp_info.erts_bin)
    environment = {
        "BINDIR": execution_root_path(bindir),
        "EMU": "beam",
        "ERL_AFLAGS": erl_env_flags(otp_runtime_erl_args(otp_info, runfiles = runfiles)),
        "ERL_ROOTDIR": execution_root_path(root),
        "PROGNAME": "erl",
        "RULES_ELIXIR_MIX_ERTS_PATH": execution_root_path(bindir),
        "ROOTDIR": execution_root_path(root),
    }
    wrapper = sdk.execution_exec_wrapper if sdk and use_execution_overlay else (sdk.execution_wrapper if sdk else None)
    if not wrapper:
        return environment
    sysroot = sdk.sysroot.short_path if runfiles else sdk.sysroot.path
    program = path_join(bindir, ".real-erlexec") if (
        getattr(otp_info, "runtime_wrapped", False) or
        use_execution_overlay and getattr(otp_info, "exec_erts_bin", "")
    ) else otp_info.erlexec.path
    if runfiles and not (use_execution_overlay and getattr(otp_info, "exec_erts_bin", "")):
        program = otp_info.erlexec.short_path
    sysroot = execution_root_path(sysroot)
    program = execution_root_path(program)
    environment.update({
        key: value.replace("{sysroot}", sysroot).replace("{program}", program)
        for key, value in sdk.execution_wrapper_environment.items()
    })
    return environment

def execution_erts_bin(otp_info, runfiles = False):
    """Return the ERTS directory runnable on the execution platform.

    Args:
      otp_info: Selected OtpInfo provider.
      runfiles: Whether to use the runfiles-relative ERTS path.

    Returns:
      The selected ERTS bin directory path.
    """
    sdk = getattr(otp_info, "crypto_sdk", None)
    if sdk and sdk.execution_exec_wrapper and getattr(otp_info, "exec_erts_bin", ""):
        return otp_info.exec_erts_bin_short_path if runfiles else otp_info.exec_erts_bin
    if getattr(otp_info, "runtime_wrapped", False):
        return otp_info.erts_bin_short_path if runfiles else otp_info.erts_bin
    return otp_info.erts_bin_short_path if runfiles else otp_info.erts_bin

def execution_erlexec(otp_info):
    """Return the erlexec launcher that can run on the execution platform.

    Cross-architecture OTP runtimes keep their real target erlexec in the
    execution overlay and expose the normalized SDK wrapper at the public
    erlexec path. Native runtimes retain the declared File executable so Bazel
    can model it directly.

    Args:
      otp_info: Selected OtpInfo provider.

    Returns:
      A File or execution-root-relative erlexec path.
    """
    sdk = getattr(otp_info, "crypto_sdk", None)
    if sdk and sdk.execution_exec_wrapper and getattr(otp_info, "exec_erts_bin", ""):
        return path_join(execution_erts_bin(otp_info), "erlexec")
    if getattr(otp_info, "runtime_wrapped", False):
        return otp_info.erlexec
    if sdk and sdk.execution_exec_wrapper:
        return sdk.execution_exec_wrapper.executable
    return otp_info.erlexec

def execution_erlexec_file(otp_info):
    """Return the declared File used to start OTP on the execution platform.

    Args:
      otp_info: Selected OtpInfo provider.

    Returns:
      The declared native erlexec or SDK execution-wrapper File.
    """
    sdk = getattr(otp_info, "crypto_sdk", None)
    if sdk and sdk.execution_exec_wrapper:
        if getattr(otp_info, "exec_erts_bin", ""):
            return sdk.execution_exec_wrapper.executable
        if getattr(otp_info, "runtime_wrapped", False):
            return otp_info.erlexec
        return sdk.execution_exec_wrapper.executable
    return otp_info.erlexec

def test_erl_launcher(ctx, otp_info):
    """Create the Bazel-owned executable required by test rules.

    The caller must include otp_runtime_env(..., runfiles=True). The launcher
    points to native erlexec and never requires a host shell.

    Args:
      ctx: Test rule context.
      otp_info: Selected OtpInfo provider.

    Returns:
      Executable symlink File owned by the test rule.
    """
    launcher = ctx.actions.declare_file(ctx.label.name + "_erl")
    target = execution_erlexec_file(otp_info)
    ctx.actions.symlink(
        output = launcher,
        target_file = target,
        is_executable = True,
    )
    return launcher

def _dependency_set(deps, provider_field):
    return depset(
        direct = deps,
        transitive = [getattr(dep[ErlangAppInfo], provider_field) for dep in deps],
        order = "preorder",
    )

def _flatten(deps, provider_field):
    flattened = _dependency_set(deps, provider_field).to_list()
    by_app = {}
    for dep in flattened:
        app_name = dep[ErlangAppInfo].app_name
        if app_name not in by_app:
            by_app[app_name] = dep
        elif by_app[app_name].label != dep.label:
            fail("conflicting targets {} and {} both provide OTP application '{}'".format(by_app[app_name].label, dep.label, app_name))
    return flattened

def compile_depset(deps):
    """Build a nested compile-dependency depset without flattening its graph."""
    return _dependency_set(deps, "compile_deps")

def runtime_depset(deps):
    """Build a nested runtime-dependency depset without flattening its graph."""
    return _dependency_set(deps, "runtime_deps")

def type_depset(deps):
    """Build a nested type-dependency depset without flattening its graph."""
    return _dependency_set(deps, "type_deps")

def flat_compile_deps(deps):
    """Return the stable closure needed to compile against `deps`.

    Args:
      deps: Direct targets providing ErlangAppInfo.

    Returns:
      Stable, application-name-deduplicated compile dependency targets.
    """
    return _flatten(deps, "compile_deps")

def flat_runtime_deps(deps):
    """Return direct and transitive runtime applications once.

    Args:
      deps: Direct targets providing ErlangAppInfo.

    Returns:
      Stable, application-name-deduplicated targets.
    """
    return _flatten(deps, "runtime_deps")

def flat_type_deps(deps):
    """Return the stable closure needed to analyze types for `deps`.

    Unlike compile_deps, this excludes build-only tools that may deliberately
    ship BEAMs without debug information.
    """
    return _flatten(deps, "type_deps")

def flat_deps(deps):
    """Compatibility alias for flat_runtime_deps.

    Args:
      deps: Direct targets providing ErlangAppInfo.

    Returns:
      Stable, application-name-deduplicated runtime targets.
    """
    return flat_runtime_deps(deps)
