"""Direct, cacheable Erlang/OTP application rule."""

load("//private:beam_info.bzl", "ErlangAppInfo", "compile_depset", "execution_erlexec", "execution_erts_bin", "flat_compile_deps", "otp_runtime_env", "runtime_depset", "type_depset")

_DRIVER_EVAL = "A=init:get_plain_arguments(),[N,S|R]=A,{ok,artifact_normalizer,NB}=compile:file(N,[binary,report_errors,report_warnings]),{module,artifact_normalizer}=code:load_binary(artifact_normalizer,N,NB),C=compile:file(S,[binary,report_errors,report_warnings]),M=element(2,C),B=element(3,C),{module,M}=code:load_binary(M,S,B),M:main(R),halt()."

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _term_list(values):
    return "[{}]".format(", ".join([_erl_string(value) for value in values]))

def _priv_destination(file):
    marker = "/priv/"
    if marker in file.short_path:
        return file.short_path.split(marker, 1)[1]
    if file.short_path.startswith("priv/"):
        return file.short_path[len("priv/"):]
    return file.basename

def _header_destination(file):
    marker = "/include/"
    if marker in file.short_path:
        return file.short_path.split(marker, 1)[1]
    if file.short_path.startswith("include/"):
        return file.short_path[len("include/"):]
    return file.basename

def _validate_define(name):
    if not name or name[0] not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ_":
        fail("Erlang macro name '{}' must start with an uppercase letter or underscore".format(name))
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
    if any([name[index] not in allowed for index in range(len(name))]):
        fail("Erlang macro name '{}' contains an invalid character".format(name))

def _validate_erlc_opts(options):
    forbidden = [
        "deterministic",
        "no_debug_info",
        "report_errors",
        "report_warnings",
        "return_errors",
        "return_warnings",
        "warnings_as_errors",
    ]
    forbidden_prefixes = ["{d,", "{i,", "{outdir,"]
    for option in options:
        normalized = option.replace(" ", "").replace("\t", "")
        if normalized in forbidden or any([normalized.startswith(prefix) for prefix in forbidden_prefixes]):
            fail("erlang_app owns compiler option '{}'".format(option))

def _erlang_app_impl(ctx):
    app_srcs = [file for file in ctx.files.srcs if file.basename.endswith(".app.src")]
    if len(app_srcs) > 1:
        fail("erlang_app accepts at most one .app.src file")
    sources = [file for file in ctx.files.srcs if not file.basename.endswith(".app.src")]
    if not sources:
        fail("erlang_app requires at least one .erl, .xrl, or .yrl source")
    _validate_erlc_opts(ctx.attr.erlc_opts)
    for name in ctx.attr.defines:
        _validate_define(name)

    compile_deps = flat_compile_deps(ctx.attr.compile_deps + ctx.attr.type_deps + ctx.attr.runtime_deps)
    toolchain = ctx.toolchains["//:otp_toolchain_type"]
    output = ctx.actions.declare_directory(ctx.label.name + "_lib")
    fingerprint = ctx.actions.declare_file(ctx.label.name + "_fingerprint")
    include_files = list(ctx.files.hdrs)
    lib_dirs = []
    for dep in compile_deps:
        include_files.extend(dep[ErlangAppInfo].include)
        for directory in dep[ErlangAppInfo].lib_dirs:
            if directory not in lib_dirs:
                lib_dirs.append(directory)
    include_dirs = []
    for file in include_files:
        if file.dirname not in include_dirs:
            include_dirs.append(file.dirname)

    config = ctx.actions.declare_file(ctx.label.name + "_erlang_build.config")
    priv_destinations = {}
    priv = []
    for file in ctx.files.priv:
        destination = _priv_destination(file)
        if destination in priv_destinations:
            fail("multiple priv inputs map to '{}' for {}".format(destination, ctx.label))
        priv_destinations[destination] = True
        priv.append("{{{}, {}}}".format(_erl_string(file.path), _erl_string(destination)))
    header_destinations = {}
    headers = []
    for file in ctx.files.hdrs:
        destination = _header_destination(file)
        if destination in header_destinations:
            fail("multiple headers map to '{}' for {}".format(destination, ctx.label))
        header_destinations[destination] = True
        headers.append("{{{}, {}}}".format(_erl_string(file.path), _erl_string(destination)))
    ctx.actions.write(
        config,
        "#{\n" + ",\n".join([
            "  app => {}".format(_erl_string(ctx.attr.app_name)),
            "  app_src => {}".format(_erl_string(app_srcs[0].path) if app_srcs else "none"),
            "  applications => {}".format(_term_list(ctx.attr.applications + [dep[ErlangAppInfo].app_name for dep in ctx.attr.runtime_deps])),
            "  defines => [{}]".format(", ".join([
                "{{{}, {}}}".format(_erl_string(name), _erl_string(ctx.attr.defines[name]))
                for name in sorted(ctx.attr.defines.keys())
            ])),
            "  erlc_opts => {}".format(_term_list(ctx.attr.erlc_opts)),
            "  headers => [{}]".format(", ".join(headers)),
            "  include_dirs => {}".format(_term_list(include_dirs)),
            "  fingerprint => {}".format(_erl_string(fingerprint.path)),
            "  output => {}".format(_erl_string(output.path)),
            "  priv => [{}]".format(", ".join(priv)),
            "  sources => {}".format(_term_list([file.path for file in sources])),
            "  version => {}".format(_erl_string(ctx.attr.version)),
            "  warnings_as_errors => {}".format("true" if ctx.attr.warnings_as_errors else "false"),
        ]) + "\n}.\n",
    )
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
    environment = otp_runtime_env(toolchain.otpinfo)
    environment.update({
        "ERL_COMPILER_OPTIONS": "deterministic",
        "ERL_LIBS": ":".join(lib_dirs),
        "HOME": output.path + ".work/home",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": execution_erts_bin(toolchain.otpinfo),
        "RULES_ELIXIR_MIX_CRYPTO_STATE": output.path + ".work/crypto_state",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = execution_erlexec(toolchain.otpinfo),
        arguments = [args],
        inputs = depset(
            direct = sources + app_srcs + include_files + ctx.files.priv + [config, ctx.file._driver, ctx.file._normalizer],
            transitive = [toolchain.runtime_files] + [dep[DefaultInfo].files for dep in compile_deps],
        ),
        outputs = [output, fingerprint],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "ERLANGAPP",
        progress_message = "Compiling Erlang OTP application {}".format(ctx.attr.app_name),
        toolchain = "//:otp_toolchain_type",
        use_default_shell_env = False,
    )

    runtime_runfiles = ctx.runfiles(files = [output])
    for dep in ctx.attr.runtime_deps:
        runtime_runfiles = runtime_runfiles.merge(dep[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(files = depset([output]), runfiles = runtime_runfiles),
        ErlangAppInfo(
            app_name = ctx.attr.app_name,
            beam = [output],
            build_roots = [output.path],
            build_roots_short_path = [output.short_path],
            compile_deps = compile_depset(ctx.attr.compile_deps + ctx.attr.type_deps + ctx.attr.runtime_deps),
            compile_fingerprint = fingerprint,
            lib_dirs = [output.path],
            lib_dirs_short_path = [output.short_path],
            deps = runtime_depset(ctx.attr.runtime_deps),
            direct_compile_deps = ctx.attr.compile_deps,
            direct_deps = ctx.attr.runtime_deps,
            direct_runtime_deps = ctx.attr.runtime_deps,
            direct_type_deps = ctx.attr.type_deps,
            extra_apps = ctx.attr.applications,
            include = ctx.files.hdrs,
            license_files = ctx.files.license_files,
            priv = ctx.files.priv,
            project_entries = [],
            project_files = [],
            project_fingerprint = None,
            project_root_short_path = "",
            runtime_deps = runtime_depset(ctx.attr.runtime_deps),
            type_deps = type_depset(ctx.attr.type_deps + ctx.attr.runtime_deps),
            srcs = ctx.files.srcs,
        ),
    ]

erlang_app = rule(
    implementation = _erlang_app_impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "srcs": attr.label_list(mandatory = True, allow_files = [".app.src", ".erl", ".xrl", ".yrl"]),
        "hdrs": attr.label_list(allow_files = [".hrl"]),
        "priv": attr.label_list(allow_files = True),
        "compile_deps": attr.label_list(providers = [ErlangAppInfo]),
        "runtime_deps": attr.label_list(providers = [ErlangAppInfo]),
        "type_deps": attr.label_list(providers = [ErlangAppInfo]),
        "applications": attr.string_list(),
        "defines": attr.string_dict(),
        "erlc_opts": attr.string_list(),
        "license_files": attr.label_list(allow_files = True),
        "warnings_as_errors": attr.bool(default = True),
        "_driver": attr.label(
            default = Label("//private:erlang_app_driver.erl"),
            allow_single_file = [".erl"],
        ),
        "_normalizer": attr.label(
            default = Label("//private:artifact_normalizer.erl"),
            allow_single_file = [".erl"],
        ),
    },
    toolchains = ["//:otp_toolchain_type"],
)
