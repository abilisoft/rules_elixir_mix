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
        "erlang_home": "Action-time OTP root containing bin/ and lib/.",
        "erlang_home_short_path": "Runfiles-relative OTP root.",
        "erl": "Compatibility alias for the declared erlexec executable.",
        "erlexec": "Declared native erlexec executable; never the bin/erl shell script.",
        "erts_bin": "Action-time ERTS directory containing beam.smp and erlexec.",
        "erts_bin_short_path": "Runfiles-relative ERTS directory.",
        "crypto_sdk": "Normalized OtpCryptoSdkInfo, or None.",
        "fips": "FIPS policy: disabled or required.",
        "version_file": "Declared version file used for cache invalidation.",
        "runtime_files": "Depset containing the OTP runtime inputs.",
        "static_crypto_nif": "Whether crypto is statically embedded into beam.smp.",
    },
)

OtpCryptoSdkInfo = provider(
    doc = "Backend-neutral static crypto SDK consumed by an OTP build.",
    fields = {
        "activation_args": "Direct argument vector for the optional activation executable.",
        "activation_exec_tool": "Execution-configured FilesToRunProvider used by build actions, or None.",
        "activation_tool": "FilesToRunProvider for activation, or None.",
        "activation_tool_release_path": "Activation executable path relative to the staged release SDK.",
        "backend_metadata": "Opaque producer metadata; rules_elixir_mix never interprets it.",
        "exec_files": "Execution-configured activation files used only by build actions.",
        "files": "Target-configured SDK and deployment files.",
        "fully_static": "Whether the SDK has no provider runtime payload or activation step.",
        "linkopts": "Backend-neutral libraries/options appended through OTP's LIBS contract.",
        "runtime_entries": "Runtime files and their SDK-relative release destinations.",
        "runtime_environment": "Environment values with {sysroot}/{activation_root} placeholders.",
        "runtime_files": "Depset containing only the deployment runtime payload.",
        "sysroot": "Directory artifact containing include/ and lib/libcrypto.a.",
    },
)

_EXECUTION_ROOT_MARKER = "/proc/self/cwd/"
_RUNTIME_PATH_EVAL = """
{ok,Cwd}=file:get_cwd(),
Marker="/proc/self/cwd/",
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
      ResolvedValue=lists:flatten(string:replace(Value,Marker,Cwd++"/",all)),
      case ResolvedValue=:=Value of
        true->ok;
        false->true=os:putenv(Key,ResolvedValue)
      end;
    _->ok
  end
end,os:getenv()),
PathKeys=["BINDIR","ERL_ROOTDIR","FIPS_MODULE_CONF","HEX_HOME","HOME","MIX_ARCHIVES","MIX_BUILD_PATH","MIX_BUILD_ROOT","MIX_DEPS_PATH","MIX_HOME","OPENSSL_CONF","OPENSSL_MODULES","REBAR_BASE_DIR","REBAR_CACHE_DIR","REBAR_CONFIG","REBAR_GLOBAL_CONFIG_DIR","ROOTDIR","RULES_ELIXIR_MIX_BUILD_CACHE_MANIFEST","RULES_ELIXIR_MIX_BUILD_MANIFEST","RULES_ELIXIR_MIX_BUILD_ROOT","RULES_ELIXIR_MIX_CRYPTO_STATE","RULES_ELIXIR_MIX_ERTS_PATH","RULES_ELIXIR_MIX_INCLUDE_MANIFEST","RULES_ELIXIR_MIX_OUTPUT","RULES_ELIXIR_MIX_PRIV_MANIFEST","RULES_ELIXIR_MIX_PROJECT_DIR","RULES_ELIXIR_MIX_PROJECT_MANIFEST","RULES_ELIXIR_MIX_DEPS_MANIFEST","RULES_ELIXIR_MIX_REBAR3","RULES_ELIXIR_MIX_REBAR_CONFIG","RULES_ELIXIR_MIX_RELEASE_ROOT","RULES_ELIXIR_MIX_FIPS_RELEASE_ROOT","RULES_ELIXIR_MIX_CRYPTO_ACTIVATION_CONFIG","RULES_ELIXIR_MIX_CRYPTO_RELEASE_HOOK","RULES_ELIXIR_MIX_CRYPTO_RELEASE_MANIFEST","RULES_ELIXIR_MIX_FIPS_RELEASE_ENFORCEMENT","TMPDIR"],
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

def _erl_string(value):
    return '"{}"'.format(
        value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t"),
    )

def _runtime_value_expression(value, sysroot_expression, activation_root = "R"):
    """Render a provider template as an Erlang iolist expression."""
    return "lists:flatten(string:replace(string:replace({value},{sysroot_token},{sysroot},all),{activation_token},{activation_root},all))".format(
        value = _erl_string(value),
        sysroot_token = _erl_string("{sysroot}"),
        sysroot = sysroot_expression,
        activation_token = _erl_string("{activation_root}"),
        activation_root = activation_root,
    )

def fips_erl_args(otp_info, runfiles = False):
    """Return VM arguments that activate crypto and set required FIPS mode early.

    Args:
      otp_info: Selected OtpInfo provider.
      runfiles: Whether paths must use runfiles-relative short paths.

    Returns:
      Erlang command-line arguments for a FIPS-required runtime, or an empty list.
    """
    fips_required = otp_info.fips == "required"
    args = ["-crypto", "fips_mode", "true"] if fips_required else []
    sdk = otp_info.crypto_sdk
    activation_tool = None
    if sdk:
        activation_tool = sdk.activation_tool if runfiles else sdk.activation_exec_tool
    if not sdk or not activation_tool:
        if not sdk and not fips_required:
            return args

        # A fully static backend must not consult OpenSSL's compiled host
        # OPENSSLDIR/MODULESDIR defaults. Point every provider/config lookup at
        # a rule-owned empty directory even when the backend ignores them.
        isolation = ",".join([
            "R0=case os:getenv(\"RULES_ELIXIR_MIX_CRYPTO_STATE\") of false->case os:getenv(\"TEST_TMPDIR\") of false->case os:getenv(\"HOME\") of false->os:getenv(\"TMPDIR\",\".\");H->H end;T->T end;V->V end",
            "R=filename:absname(filename:join(R0,\"crypto_isolation\"))",
            "ok=filelib:ensure_dir(filename:join(R,\".keep\"))",
            "C=filename:join(R,\"openssl.cnf\")",
            "ok=file:write_file(C,<<>>)",
            "true=os:putenv(\"OPENSSL_CONF\",C)",
            "true=os:putenv(\"OPENSSL_MODULES\",R)",
            "true=os:putenv(\"FIPS_MODULE_CONF\",C)",
            "ok",
        ])
        return args + [
            "-eval",
            "begin " + isolation + " end.",
        ]

    sysroot = sdk.sysroot.short_path if runfiles else sdk.sysroot.path
    executable = activation_tool.executable.short_path if runfiles else activation_tool.executable.path
    activation_args = [
        _runtime_value_expression(value, "SdkRoot")
        for value in sdk.activation_args
    ]
    runtime_environment = [
        "true=os:putenv({},{})".format(
            _erl_string(key),
            _runtime_value_expression(sdk.runtime_environment[key], "SdkRoot"),
        )
        for key in sorted(sdk.runtime_environment.keys())
    ]
    expression = ",".join([
        "SdkRoot=filename:absname(%s)" % _erl_string(sysroot),
        "R0=case os:getenv(\"RULES_ELIXIR_MIX_CRYPTO_STATE\") of false->case os:getenv(\"TEST_TMPDIR\") of false->case os:getenv(\"HOME\") of false->os:getenv(\"TMPDIR\",\".\");H->H end;T->T end;V->V end",
        "R=filename:absname(filename:join(R0,\"crypto_activation\"))",
        "ok=filelib:ensure_dir(filename:join(R,\".keep\"))",
        "I=filename:join(R,\"isolation\")",
        "ok=filelib:ensure_dir(filename:join(I,\".keep\"))",
        "C=filename:join(I,\"openssl.cnf\")",
        "ok=file:write_file(C,<<>>)",
        "true=os:putenv(\"OPENSSL_CONF\",C)",
        "true=os:putenv(\"OPENSSL_MODULES\",I)",
        "true=os:putenv(\"FIPS_MODULE_CONF\",C)",
        "P=open_port({spawn_executable,filename:absname(%s)},[binary,exit_status,stderr_to_stdout,use_stdio,{args,[%s]}])" % (
            _erl_string(executable),
            ",".join(activation_args),
        ),
        "A=fun F()->receive {P,{data,D}}->io:put_chars(standard_error,D),F();{P,{exit_status,0}}->ok;{P,{exit_status,Status}}->erlang:error({crypto_activation_failed,Status}) end end",
        "ok=A()",
    ] + runtime_environment + ["ok"])
    return args + ["-eval", "begin " + expression + " end."]

def crypto_exec_inputs(otp_info):
    """Return execution-configured provider activation inputs for an action."""
    sdk = otp_info.crypto_sdk
    return depset(
        direct = [sdk.sysroot],
        transitive = [sdk.exec_files],
    ) if sdk and sdk.activation_exec_tool else depset()

def crypto_exec_tools(otp_info):
    """Return execution-configured provider activation tools for an action."""
    sdk = otp_info.crypto_sdk
    return [sdk.activation_exec_tool] if sdk and sdk.activation_exec_tool else []

def crypto_runtime_files(otp_info):
    """Return target-configured crypto deployment files needed at runtime.

    Fully static SDKs deliberately contribute nothing: their sysroot is a
    build input, not release payload. Provider-backed SDKs need the normalized
    target-configured SDK closure because their early activation expression
    references both the sysroot and the activation executable through runfiles.
    """
    sdk = otp_info.crypto_sdk
    return sdk.files if sdk and sdk.activation_tool else depset()

def otp_runtime_env(otp_info, runfiles = False):
    """Return the environment required to invoke erlexec directly.

    Args:
      otp_info: Selected OtpInfo provider.
      runfiles: Whether paths must be runfiles-relative short paths.

    Returns:
      A deterministic environment fragment for the native VM launcher.
    """
    root = otp_info.erlang_home_short_path if runfiles else otp_info.erlang_home
    bindir = otp_info.erts_bin_short_path if runfiles else otp_info.erts_bin
    return {
        "BINDIR": execution_root_path(bindir),
        "EMU": "beam",
        "ERL_AFLAGS": erl_env_flags(runtime_path_erl_args()),
        "ERL_ROOTDIR": execution_root_path(root),
        "PROGNAME": "erl",
        "RULES_ELIXIR_MIX_ERTS_PATH": execution_root_path(bindir),
        "ROOTDIR": execution_root_path(root),
    }

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
    ctx.actions.symlink(
        output = launcher,
        target_file = otp_info.erlexec,
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
