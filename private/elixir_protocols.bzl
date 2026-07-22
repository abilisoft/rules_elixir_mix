"""Cacheable whole-runtime Elixir protocol consolidation."""

load("//private:beam_info.bzl", "ErlangAppInfo", "execution_erlexec", "execution_erts_bin", "flat_runtime_deps", "otp_runtime_env", "path_join")

ElixirProtocolInfo = provider(
    doc = "Consolidated protocol BEAM files for one runtime application closure.",
    fields = {
        "directory": "Tree artifact containing consolidated protocol BEAM files.",
    },
)

_CONSOLIDATE = """
[output | roots] = System.argv()
paths =
  roots
  |> Enum.flat_map(&Path.wildcard(Path.join([&1, "*", "ebin"])))
  |> Kernel.++(Path.wildcard(Path.join([System.fetch_env!("RULES_ELIXIR_MIX_ELIXIR_HOME"), "lib", "*", "ebin"])))
  |> Enum.uniq()
  |> Enum.sort()

File.mkdir_p!(output)
paths
|> Protocol.extract_protocols()
|> Enum.sort()
|> Enum.each(fn protocol ->
  implementations = Protocol.extract_impls(protocol, paths) |> Enum.sort()
  case Protocol.consolidate(protocol, implementations) do
    {:ok, binary} -> File.write!(Path.join(output, Atom.to_string(protocol) <> ".beam"), binary)
    {:error, reason} -> raise "cannot consolidate #{inspect(protocol)}: #{inspect(reason)}"
  end
end)
File.rm_rf!(Path.join(output, ".state"))
"""

def _elixir_protocols_impl(ctx):
    apps = flat_runtime_deps(ctx.attr.apps)
    if not apps:
        fail("elixir_protocols requires at least one application")
    output = ctx.actions.declare_directory(ctx.label.name + "_consolidated")
    toolchain = ctx.toolchains["//:toolchain_type"]
    roots = []
    for app in apps:
        for lib_dir in app[ErlangAppInfo].lib_dirs:
            if lib_dir not in roots:
                roots.append(lib_dir)

    args = ctx.actions.args()
    args.add_all([
        "-noshell",
        "+fnu",
        "-s",
        "elixir",
        "start_cli",
        "-extra",
        "-e",
        _CONSOLIDATE,
        "--",
        output.path,
    ])
    args.add_all(roots)

    environment = otp_runtime_env(toolchain.otpinfo)
    environment.update({
        "ERL_COMPILER_OPTIONS": "deterministic",
        "ERL_LIBS": ":".join([path_join(toolchain.elixirinfo.elixir_home, "lib")] + roots),
        "HOME": output.path + "/.state/home",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": execution_erts_bin(toolchain.otpinfo),
        "RULES_ELIXIR_MIX_ELIXIR_HOME": toolchain.elixirinfo.elixir_home,
        "RULES_ELIXIR_MIX_CRYPTO_STATE": output.path + "/.state/crypto",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = execution_erlexec(toolchain.otpinfo),
        arguments = [args],
        inputs = depset(
            transitive = [toolchain.runtime_files] + [
                app[DefaultInfo].files
                for app in apps
            ],
        ),
        outputs = [output],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "ELIXIRPROTOCOLS",
        progress_message = "Consolidating Elixir protocols for {}".format(ctx.label),
        toolchain = "//:toolchain_type",
        use_default_shell_env = False,
    )
    return [
        DefaultInfo(files = depset([output]), runfiles = ctx.runfiles(files = [output])),
        ElixirProtocolInfo(directory = output),
    ]

elixir_protocols = rule(
    implementation = _elixir_protocols_impl,
    attrs = {
        "apps": attr.label_list(mandatory = True, providers = [ErlangAppInfo]),
    },
    toolchains = ["//:toolchain_type"],
)
