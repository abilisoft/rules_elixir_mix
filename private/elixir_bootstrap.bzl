"""Small shell-free bootstrap rule used only to break the Hex/Jason cycle."""

load("//private:beam_info.bzl", "ErlangAppInfo", "crypto_exec_inputs", "crypto_exec_tools", "fips_erl_args", "otp_runtime_env")

_COMPILE = """
[output, fingerprint, app, version | sources] = System.argv()
ebin = Path.join([output, app, "ebin"])
File.mkdir_p!(ebin)
{:ok, modules, _warnings} = Kernel.ParallelCompiler.compile_to_path(sources, ebin)
application = {:application, String.to_atom(app), [vsn: String.to_charlist(version), modules: modules, applications: [:kernel, :stdlib, :elixir, :logger]]}
File.write!(Path.join(ebin, app <> ".app"), :io_lib.format("~tp.~n", [application]))
entries =
  Path.wildcard(Path.join([output, app, "**/*"]), match_dot: true)
  |> Enum.sort()
  |> Enum.map(fn path ->
    stat = File.lstat!(path)
    relative = Path.relative_to(path, Path.join(output, app))
    mode = Bitwise.band(stat.mode, 0o777)
    case stat.type do
      :regular ->
        content = File.read!(path)
        {
          relative,
          :regular,
          mode,
          byte_size(content),
          :erlang.phash2(content, 4_294_967_296),
          :erlang.phash2({:rules_elixir_mix, content}, 4_294_967_296),
        }
      :symlink -> {relative, :symlink, mode, File.read_link!(path)}
      type -> {relative, type, mode}
    end
  end)
File.write!(fingerprint, :erlang.term_to_binary(entries, [:deterministic]))
File.rm_rf!(Path.join(output, ".state"))
"""

def _elixir_bootstrap_app_impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name + "_lib")
    fingerprint = ctx.actions.declare_file(ctx.label.name + "_fingerprint")
    toolchain = ctx.toolchains["//:toolchain_type"]
    args = ctx.actions.args()
    args.add_all([
        "-noshell",
        "+fnu",
    ] + fips_erl_args(toolchain.otpinfo) + [
        "-s",
        "elixir",
        "start_cli",
        "-extra",
        "-e",
        _COMPILE,
        "--",
        output.path,
        fingerprint.path,
        ctx.attr.app_name,
        ctx.attr.version,
    ])
    args.add_all(ctx.files.srcs)

    environment = otp_runtime_env(toolchain.otpinfo)
    environment.update({
        "ERL_COMPILER_OPTIONS": "deterministic",
        "ERL_LIBS": toolchain.elixirinfo.elixir_home + "/lib",
        "HOME": output.path + "/.state/home",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": toolchain.otpinfo.erts_bin,
        "RULES_ELIXIR_MIX_CRYPTO_STATE": output.path + "/.state/crypto",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = toolchain.otpinfo.erlexec,
        arguments = [args],
        inputs = depset(direct = ctx.files.srcs, transitive = [toolchain.runtime_files, crypto_exec_inputs(toolchain.otpinfo)]),
        tools = crypto_exec_tools(toolchain.otpinfo),
        outputs = [output, fingerprint],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "ELIXIRBOOTSTRAP",
        toolchain = "//:toolchain_type",
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([output]), runfiles = ctx.runfiles(files = [output])),
        ErlangAppInfo(
            app_name = ctx.attr.app_name,
            beam = [output],
            build_roots = [output.path],
            build_roots_short_path = [output.short_path],
            compile_deps = depset(),
            compile_fingerprint = fingerprint,
            lib_dirs = [output.path],
            lib_dirs_short_path = [output.short_path],
            deps = depset(),
            direct_compile_deps = [],
            direct_deps = [],
            direct_runtime_deps = [],
            extra_apps = [],
            include = [],
            license_files = [],
            priv = [],
            project_entries = [],
            project_files = [],
            project_fingerprint = None,
            project_root_short_path = "",
            runtime_deps = depset(),
            srcs = ctx.files.srcs,
        ),
    ]

elixir_bootstrap_app = rule(
    implementation = _elixir_bootstrap_app_impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "srcs": attr.label_list(mandatory = True, allow_files = [".ex"]),
    },
    toolchains = ["//:toolchain_type"],
)
