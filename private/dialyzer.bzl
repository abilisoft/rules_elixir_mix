"""Cacheable Dialyzer PLTs and shell-free BEAM analysis tests."""

load("//private:beam_info.bzl", "ErlangAppInfo", "crypto_exec_inputs", "crypto_exec_tools", "crypto_runtime_files", "erl_env_flags", "fips_erl_args", "flat_type_deps", "otp_runtime_env", "path_join", "runtime_path_erl_args", "test_erl_launcher")

DialyzerPltInfo = provider(
    doc = "A cacheable Dialyzer persistent lookup table.",
    fields = {
        "apps": "Sorted OTP application names included in the PLT.",
        "elixir_version": "Elixir version used to build the PLT.",
        "file": "The declared PLT file.",
        "otp_version": "OTP version used to build the PLT.",
    },
)

_BUILD_PLT = """
[output | roots] = System.argv()
beam_dirs =
  roots
  |> Enum.flat_map(&Path.wildcard(Path.join([&1, "*", "ebin"])))
  |> Kernel.++(Path.wildcard(Path.join([System.fetch_env!("RULES_ELIXIR_MIX_ELIXIR_HOME"), "lib", "*", "ebin"])))

otp_dirs =
  System.fetch_env!("RULES_ELIXIR_MIX_OTP_PLT_APPS")
  |> String.split(",", trim: true)
  |> Enum.flat_map(fn app ->
    case app |> String.to_atom() |> :code.lib_dir(:ebin) do
      path when is_list(path) -> [to_string(path)]
      {:error, :bad_name} -> []
    end
  end)

directories = (beam_dirs ++ otp_dirs) |> Enum.uniq() |> Enum.sort()
File.mkdir_p!(Path.dirname(output))
_warnings = :dialyzer.run([
  {:analysis_type, :plt_build},
  {:files_rec, Enum.map(directories, &String.to_charlist/1)},
  {:from, :byte_code},
  # A PLT is a cached type-information substrate, not an analysis verdict for
  # third-party libraries. Report warnings only when the consumer's explicit
  # analysis target runs against the PLT.
  {:get_warnings, false},
  {:output_plt, String.to_charlist(output)},
])

defmodule RulesElixirMix.PltNormalizer do
  def rewrite(value, from, to) when is_binary(value) do
    :binary.replace(value, from, to, [:global])
  end

  def rewrite(value, from, to) when is_list(value) do
    case byte_list(value) do
      {:ok, binary} -> binary |> :binary.replace(from, to, [:global]) |> :binary.bin_to_list()
      :error -> rewrite_cons(value, from, to)
    end
  end

  def rewrite(value, from, to)
      when is_tuple(value) and tuple_size(value) == 9 and elem(value, 0) == :dict do
    value
    |> :dict.to_list()
    |> Enum.map(fn {key, item} -> {rewrite(key, from, to), rewrite(item, from, to)} end)
    |> Enum.sort()
    |> :dict.from_list()
  end

  def rewrite({:contract, pairs, args, forms}, from, to) do
    canonical_pairs =
      Enum.map(pairs, fn {type, constraints} ->
        canonical_constraints =
          constraints
          |> Enum.map(&rewrite(&1, from, to))
          |> Enum.sort()

        {rewrite(type, from, to), canonical_constraints}
      end)

    {:contract, canonical_pairs, rewrite(args, from, to), rewrite(forms, from, to)}
  end

  def rewrite(value, from, to) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&rewrite(&1, from, to)) |> List.to_tuple()
  end

  def rewrite(value, from, to) when is_map(value) do
    Map.new(value, fn {key, item} -> {rewrite(key, from, to), rewrite(item, from, to)} end)
  end

  def rewrite(value, _from, _to), do: value

  defp rewrite_cons([], _from, _to), do: []
  defp rewrite_cons([head | tail], from, to) do
    [rewrite(head, from, to) | rewrite_tail(tail, from, to)]
  end

  defp rewrite_tail([], _from, _to), do: []
  defp rewrite_tail([_head | _tail] = value, from, to), do: rewrite_cons(value, from, to)
  defp rewrite_tail(value, from, to), do: rewrite(value, from, to)

  defp byte_list(value) do
    try do
      {:ok, :erlang.list_to_binary(value)}
    rescue
      ArgumentError -> :error
    end
  end
end

cwd = File.cwd!()
stable_root = "/rules_elixir_mix/execroot"
rewritten =
  output
  |> File.read!()
  |> :erlang.binary_to_term()
  |> RulesElixirMix.PltNormalizer.rewrite(cwd, stable_root)

probe = :erlang.term_to_binary(rewritten, [:deterministic])
if :binary.match(probe, cwd) != :nomatch do
  raise "Dialyzer PLT retained the action execution root"
end

File.write!(output, :erlang.term_to_binary(rewritten, [:compressed, :deterministic]))
File.rm_rf!(System.fetch_env!("RULES_ELIXIR_MIX_STATE_DIR"))
"""

_ANALYZE = """
[plt | roots] = System.argv()
record = plt |> File.read!() |> :erlang.binary_to_term()
implementation = elem(record, 9)
expected_implementation = MapSet.new(["erl_bif_types", "erl_types"])
actual_implementation =
  implementation
  |> Enum.map(fn {path, _digest} -> path |> to_string() |> Path.basename(".beam") end)
  |> MapSet.new()

if actual_implementation != expected_implementation do
  raise "unexpected Dialyzer implementation entries: #{inspect(actual_implementation)}"
end

hydrated_implementation =
  Enum.map(implementation, fn {path, digest} ->
    module = path |> to_string() |> Path.basename(".beam") |> String.to_atom()
    runtime_path = module |> :code.which() |> to_string()
    if not File.regular?(runtime_path), do: raise("Dialyzer implementation module is unavailable: #{module}")
    {String.to_charlist(runtime_path), digest}
  end)

hydrated_plt = Path.join(System.fetch_env!("TEST_TMPDIR"), "hydrated.plt")
record
|> put_elem(9, hydrated_implementation)
|> :erlang.term_to_binary([:compressed, :deterministic])
|> then(&File.write!(hydrated_plt, &1))

directories =
  roots
  |> Enum.flat_map(&Path.wildcard(Path.join([&1, "*", "ebin"])))
  |> Enum.uniq()
  |> Enum.sort()

warning_options =
  System.get_env("RULES_ELIXIR_MIX_DIALYZER_WARNINGS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

options = [
  {:analysis_type, :succ_typings},
  {:check_plt, false},
  {:files_rec, Enum.map(directories, &String.to_charlist/1)},
  {:from, :byte_code},
  {:get_warnings, true},
  {:init_plt, String.to_charlist(hydrated_plt)},
]
options = if warning_options == [], do: options, else: [{:warnings, warning_options} | options]
warnings = :dialyzer.run(options)
Enum.each(warnings, &:io.put_chars(:dialyzer.format_warning(&1)))
System.halt(if warnings == [], do: 0, else: 1)
"""

def _dedupe_roots(apps, short_path = False):
    roots = []
    for app in apps:
        info = app[ErlangAppInfo]
        values = info.lib_dirs_short_path if short_path else info.lib_dirs
        for value in values:
            if value not in roots:
                roots.append(value)
    return roots

def _dialyzer_plt_impl(ctx):
    if ctx.attr.apps and ctx.attr.deps:
        fail("dialyzer_plt apps and deps are aliases; set only deps")
    apps = flat_type_deps(ctx.attr.deps or ctx.attr.apps)
    roots = _dedupe_roots(apps)
    output = ctx.actions.declare_file(ctx.label.name + ".plt")
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
        _BUILD_PLT,
        "--",
        output.path,
    ])
    args.add_all(roots)

    environment = otp_runtime_env(toolchain.otpinfo)
    environment.update({
        "ERL_LIBS": ":".join([path_join(toolchain.elixirinfo.elixir_home, "lib")] + roots),
        "HOME": output.path + ".state/home",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": toolchain.otpinfo.erts_bin,
        "RULES_ELIXIR_MIX_ELIXIR_HOME": toolchain.elixirinfo.elixir_home,
        "RULES_ELIXIR_MIX_CRYPTO_STATE": output.path + ".state/crypto",
        "RULES_ELIXIR_MIX_OTP_PLT_APPS": ",".join(ctx.attr.otp_apps),
        "RULES_ELIXIR_MIX_STATE_DIR": output.path + ".state",
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = toolchain.otpinfo.erlexec,
        arguments = [args],
        inputs = depset(
            transitive = [toolchain.runtime_files, crypto_exec_inputs(toolchain.otpinfo)] + [
                app[DefaultInfo].files
                for app in apps
            ],
        ),
        tools = crypto_exec_tools(toolchain.otpinfo),
        outputs = [output],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "DIALYZERPLT",
        progress_message = "Building Dialyzer PLT {}".format(ctx.label),
        toolchain = "//:toolchain_type",
        use_default_shell_env = False,
    )
    return [
        DefaultInfo(files = depset([output]), runfiles = ctx.runfiles(files = [output])),
        DialyzerPltInfo(
            apps = sorted([app[ErlangAppInfo].app_name for app in apps]),
            elixir_version = toolchain.elixirinfo.version,
            file = output,
            otp_version = toolchain.otpinfo.version,
        ),
    ]

dialyzer_plt = rule(
    implementation = _dialyzer_plt_impl,
    attrs = {
        "apps": attr.label_list(providers = [ErlangAppInfo]),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "otp_apps": attr.string_list(default = [
            "compiler",
            "crypto",
            "erts",
            "kernel",
            "public_key",
            "ssl",
            "stdlib",
        ]),
    },
    toolchains = ["//:toolchain_type"],
)

def _elixir_dialyzer_test_impl(ctx):
    analyzed_apps = ctx.attr.apps
    type_apps = flat_type_deps(analyzed_apps)
    analysis_roots = _dedupe_roots(analyzed_apps, short_path = True)
    type_roots = _dedupe_roots(type_apps, short_path = True)
    toolchain = ctx.toolchains["//:toolchain_type"]
    plt_info = ctx.attr.plt[DialyzerPltInfo]
    plt = plt_info.file
    if plt_info.otp_version != toolchain.otpinfo.version or plt_info.elixir_version != toolchain.elixirinfo.version:
        fail("Dialyzer PLT toolchain mismatch: PLT uses OTP {}/Elixir {}, analysis uses OTP {}/Elixir {}".format(
            plt_info.otp_version,
            plt_info.elixir_version,
            toolchain.otpinfo.version,
            toolchain.elixirinfo.version,
        ))
    analyzed_names = {app[ErlangAppInfo].app_name: True for app in analyzed_apps}
    required_plt_apps = {
        app[ErlangAppInfo].app_name: True
        for app in type_apps
        if app[ErlangAppInfo].app_name not in analyzed_names
    }
    missing = sorted([name for name in required_plt_apps if name not in plt_info.apps])
    if missing:
        fail("Dialyzer PLT is missing compile/type dependencies {}; build it with deps = [...] rather than the analyzed roots".format(missing))
    args = runtime_path_erl_args() + [
        "-noshell",
        "+fnu",
    ] + fips_erl_args(toolchain.otpinfo, runfiles = True) + [
        "-s",
        "elixir",
        "start_cli",
        "-extra",
        "-e",
        _ANALYZE,
        "--",
        plt.short_path,
    ] + analysis_roots
    environment = otp_runtime_env(toolchain.otpinfo, runfiles = True)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(args),
        "ERL_LIBS": ":".join([path_join(toolchain.elixirinfo.elixir_home_short_path, "lib")] + type_roots),
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "RULES_ELIXIR_MIX_DIALYZER_WARNINGS": ",".join(ctx.attr.warning_options),
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })

    runfiles = ctx.runfiles(
        files = [plt],
        transitive_files = depset(transitive = [
            toolchain.runtime_files,
            crypto_runtime_files(toolchain.otpinfo),
        ]),
    ).merge(ctx.attr.plt[DefaultInfo].default_runfiles)
    for app in type_apps:
        runfiles = runfiles.merge(app[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = test_erl_launcher(ctx, toolchain.otpinfo), runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
    ]

elixir_dialyzer_test = rule(
    implementation = _elixir_dialyzer_test_impl,
    attrs = {
        "apps": attr.label_list(mandatory = True, providers = [ErlangAppInfo]),
        "plt": attr.label(mandatory = True, providers = [DialyzerPltInfo]),
        "warning_options": attr.string_list(),
    },
    test = True,
    toolchains = ["//:toolchain_type"],
)
