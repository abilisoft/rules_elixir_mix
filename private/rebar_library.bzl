"""Shell-free Rebar3 compilation for Erlang Hex applications."""

load("//private:beam_info.bzl", "ErlangAppInfo", "compile_depset", "crypto_exec_inputs", "crypto_exec_tools", "erl_env_flags", "fips_erl_args", "flat_compile_deps", "otp_runtime_env", "path_join", "runtime_depset", "type_depset")

_RebarCompileInfo = provider(
    doc = "Internal result of a Rebar3 compile action.",
    fields = {
        "fingerprint": "Deterministic compiled-application fingerprint.",
        "project_fingerprint": "Deterministic staged source-project fingerprint.",
    },
)

_REBAR_EVAL = """
project = Path.absname(System.fetch_env!("RULES_ELIXIR_MIX_PROJECT_DIR"))
project_manifest = Path.absname(System.fetch_env!("RULES_ELIXIR_MIX_PROJECT_MANIFEST"))
base = Path.absname(System.fetch_env!("REBAR_BASE_DIR"))
source_config = Path.absname(System.fetch_env!("RULES_ELIXIR_MIX_REBAR_CONFIG"))
# Rebar3 loads rebar.config from the project root. Replacing the staged copy
# is what prevents its package manager from traversing/fetching dependencies;
# the dependencies themselves are separate Bazel inputs on ERL_LIBS.
generated_config = Path.join(project, "rebar.config")
rebar3 = Path.absname(System.fetch_env!("RULES_ELIXIR_MIX_REBAR3"))
escript = Path.absname(System.fetch_env!("RULES_ELIXIR_MIX_ESCRIPT"))
fingerprint = Path.absname(System.fetch_env!("RULES_ELIXIR_MIX_COMPILE_FINGERPRINT"))
project_fingerprint = Path.absname(System.fetch_env!("RULES_ELIXIR_MIX_PROJECT_FINGERPRINT"))

resolve_input = fn resolve_input, source ->
  case File.lstat!(source).type do
    :symlink ->
      target = File.read_link!(source) |> Path.expand(Path.dirname(source))
      resolve_input.(resolve_input, target)
    _ -> source
  end
end
copy_input = fn copy_input, source, destination ->
  source = resolve_input.(resolve_input, source)
  stat = File.lstat!(source)
  case stat.type do
    :directory ->
      File.mkdir_p!(destination)
      File.chmod!(destination, Bitwise.band(stat.mode, 0o777))
      source
      |> File.ls!()
      |> Enum.each(&copy_input.(copy_input, Path.join(source, &1), Path.join(destination, &1)))
    :regular ->
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
      File.chmod!(destination, Bitwise.band(stat.mode, 0o777))
    type ->
      raise "unsupported Rebar project input type #{inspect(type)}: #{source}"
  end
end
fingerprint_tree = fn root ->
  Path.wildcard(Path.join(root, "**/*"), match_dot: true)
  |> Enum.sort()
  |> Enum.map(fn path ->
    stat = File.lstat!(path)
    relative = Path.relative_to(path, root)
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
end

File.rm_rf!(project)
File.mkdir_p!(project)
{:ok, [project_entries]} = :file.consult(String.to_charlist(project_manifest))
Enum.each(project_entries, fn {source, relative} ->
  copy_input.(copy_input, to_string(source), Path.join(project, to_string(relative)))
end)
File.mkdir_p!(Path.dirname(project_fingerprint))
File.write!(project_fingerprint, :erlang.term_to_binary(fingerprint_tree.(project), [:deterministic]))
# The lock remains part of the action and source fingerprint, but Rebar must
# not resolve it: the lock has already been converted into Bazel dependency
# edges and every archive is a separate checksum-pinned repository input.
File.rm(Path.join(project, "rebar.lock"))

{:ok, terms} = :file.consult(String.to_charlist(source_config))
# Hex packages are compiled as isolated roots, but project_plugins are only
# development/publishing tools when the package is consumed as a dependency.
terms = Keyword.drop(terms, [:project_plugins, :project_plugin_dirs])
compile_shell_hook? = fn
  {:compile, _command} -> true
  {_platform, :compile, _command} -> true
  _hook -> false
end
compile_provider_hook? = fn
  {:compile, _provider} -> true
  _hook -> false
end
walk = fn walk, active_terms, profile ->
  Enum.each(active_terms, fn
    {:profiles, profiles} ->
      Enum.each(profiles, fn
        {:default, profile_terms} -> walk.(walk, profile_terms, :default_profile)
        _inactive_profile -> :ok
      end)
    {key, value} = term when key in [:pre_hooks, :post_hooks] ->
      if Enum.any?(value, compile_shell_hook?),
        do: raise("rules_elixir_mix does not execute Rebar3 compile hooks in #{profile}: #{inspect(term)}")
    {:provider_hooks, hooks} = term ->
      active? =
        Enum.any?(hooks, fn
          {_phase, mappings} -> Enum.any?(mappings, compile_provider_hook?)
          _hook -> false
        end)
      if active?,
        do: raise("rules_elixir_mix does not execute Rebar3 compile provider hooks in #{profile}: #{inspect(term)}")
    {:plugins, value} = term ->
      if value != [],
        do: raise("rules_elixir_mix does not execute Rebar3 plugins in #{profile}: #{inspect(term)}")
    _term -> :ok
  end)
end
walk.(walk, terms, :top_level)

terms = List.keystore(terms, :deps, 0, {:deps, []})
File.mkdir_p!(base)
File.write!(generated_config, Enum.map(terms, &:io_lib.format(~c"~tp.~n", [&1])))
System.put_env("REBAR_BASE_DIR", base)
System.put_env("REBAR_CACHE_DIR", Path.join([base, ".state", "cache"]))
System.put_env("REBAR_CONFIG", generated_config)
System.put_env("REBAR_GLOBAL_CONFIG_DIR", Path.join([base, ".state", "config"]))
File.cd!(project)
{command_output, status} = System.cmd(escript, [rebar3, "compile"],
  env: [{"ERL_AFLAGS", System.fetch_env!("RULES_ELIXIR_MIX_REBAR_ERL_AFLAGS")}],
  stderr_to_stdout: true
)
IO.binwrite(command_output)
if status != 0, do: raise("Rebar3 compile failed with status #{status}")
app = System.fetch_env!("RULES_ELIXIR_MIX_APP")
app_file = Path.join([base, "default", "lib", app, "ebin", app <> ".app"])
if not File.regular?(app_file), do: raise("Rebar3 did not emit expected OTP application #{app}: #{app_file}")
{:ok, [{:application, emitted, _properties}]} = :file.consult(String.to_charlist(app_file))
if Atom.to_string(emitted) != app do
  raise "Rebar3 emitted OTP application #{inspect(emitted)} but Bazel target declares #{inspect(app)}"
end
materialize = fn materialize, path ->
  case File.lstat(path) do
    {:ok, %{type: :symlink}} ->
      target = File.read_link!(path) |> Path.expand(Path.dirname(path))
      File.rm!(path)
      cond do
        File.dir?(target) -> File.cp_r!(target, path)
        File.regular?(target) -> File.cp!(target, path)
        true -> :ok
      end
      if File.exists?(path), do: materialize.(materialize, path)
    {:ok, %{type: :directory}} ->
      path |> File.ls!() |> Enum.each(&materialize.(materialize, Path.join(path, &1)))
    {:ok, _stat} -> :ok
    {:error, :enoent} -> :ok
  end
end
app_root = Path.join([base, "default", "lib", app])
materialize.(materialize, app_root)
entries = fingerprint_tree.(app_root)
File.mkdir_p!(Path.dirname(fingerprint))
File.write!(fingerprint, :erlang.term_to_binary(entries, [:deterministic]))
File.rm_rf!(Path.join(base, ".state"))
"""

def _toolchain(ctx):
    return ctx.toolchains["//:toolchain_type"]

def _app_lib_dirs(deps):
    result = []
    for dep in flat_compile_deps(deps):
        for lib_dir in dep[ErlangAppInfo].lib_dirs:
            if lib_dir not in result:
                result.append(lib_dir)
    return result

def _project_manifest(ctx, files):
    entries = _project_entries(ctx, files)
    manifest = ctx.actions.declare_file(ctx.label.name + "_project_manifest")
    ctx.actions.write(
        manifest,
        "[{}].\n".format(", ".join([
            "{{{}, {}}}".format(_erl_string(entry.source.path), _erl_string(entry.destination))
            for entry in entries
        ])),
    )
    return manifest

def _project_entries(ctx, files):
    config_path = ctx.file.rebar_config.short_path
    root = config_path.rsplit("/", 1)[0] if "/" in config_path else ""
    prefix = root.rstrip("/") + "/" if root else ""
    destinations = {}
    entries = []
    for file in files:
        if prefix and file.short_path.startswith(prefix):
            relative = file.short_path[len(prefix):]
        elif not prefix and not file.short_path.startswith("../"):
            relative = file.short_path
        else:
            fail("Rebar project input {} is outside source root '{}'".format(file, root or "."))
        if not relative or relative.startswith("/") or "\\" in relative or any([part in ["", ".", ".."] for part in relative.split("/")]):
            fail("Rebar project input {} has unsafe relative path '{}'".format(file, relative))
        if relative in destinations:
            if destinations[relative].path != file.path:
                fail("Rebar project inputs {} and {} both map to '{}'".format(destinations[relative], file, relative))
            continue
        destinations[relative] = file
        entries.append(struct(destination = relative, source = file))
    if ctx.file.rebar_config.basename not in destinations:
        fail("rebar_config must be staged below its project root")
    return entries

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _rebar_compile_impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name + "_build")
    fingerprint = ctx.actions.declare_file(ctx.label.name + "_fingerprint")
    project_fingerprint = ctx.actions.declare_file(ctx.label.name + "_project_fingerprint")
    toolchain = _toolchain(ctx)
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
        _REBAR_EVAL,
    ])

    deps = flat_compile_deps(ctx.attr.compile_deps + ctx.attr.type_deps + ctx.attr.runtime_deps)
    inputs = ctx.files.srcs + ctx.files.priv + ctx.files.include + [ctx.file.rebar_config, ctx.file.rebar3]
    project_manifest = _project_manifest(ctx, ctx.files.srcs + ctx.files.priv + ctx.files.include + [ctx.file.rebar_config])
    environment = otp_runtime_env(toolchain.otpinfo)
    environment.update({
        "ERL_COMPILER_OPTIONS": "deterministic",
        "ERL_LIBS": ":".join(
            [path_join(toolchain.elixirinfo.elixir_home, "lib")] +
            _app_lib_dirs(deps),
        ),
        "HEX_OFFLINE": "true",
        "HOME": path_join(output.path, ".state", "home"),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": toolchain.otpinfo.erts_bin,
        "REBAR_BASE_DIR": output.path,
        "REBAR_CACHE_DIR": path_join(output.path, ".state", "cache"),
        "REBAR_COLOR": "none",
        "REBAR_GLOBAL_CONFIG_DIR": path_join(output.path, ".state", "config"),
        "RULES_ELIXIR_MIX_PROJECT_DIR": path_join(output.path, ".state", "project"),
        "RULES_ELIXIR_MIX_PROJECT_MANIFEST": project_manifest.path,
        "RULES_ELIXIR_MIX_APP": ctx.attr.app_name,
        "RULES_ELIXIR_MIX_CRYPTO_STATE": path_join(output.path, ".state", "crypto"),
        "RULES_ELIXIR_MIX_COMPILE_FINGERPRINT": fingerprint.path,
        "RULES_ELIXIR_MIX_PROJECT_FINGERPRINT": project_fingerprint.path,
        "RULES_ELIXIR_MIX_ESCRIPT": path_join(toolchain.otpinfo.erts_bin, "escript"),
        "RULES_ELIXIR_MIX_REBAR_ERL_AFLAGS": erl_env_flags(
            ["+fnu"] + (["-crypto", "fips_mode", "true"] if toolchain.otpinfo.fips == "required" else []),
        ),
        "RULES_ELIXIR_MIX_REBAR3": ctx.file.rebar3.path,
        "RULES_ELIXIR_MIX_REBAR_CONFIG": ctx.file.rebar_config.path,
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    ctx.actions.run(
        executable = toolchain.otpinfo.erlexec,
        arguments = [args],
        inputs = depset(
            direct = inputs + [project_manifest],
            transitive = [toolchain.runtime_files, crypto_exec_inputs(toolchain.otpinfo)] + [
                dep[DefaultInfo].files
                for dep in deps
            ],
        ),
        tools = crypto_exec_tools(toolchain.otpinfo),
        outputs = [output, fingerprint, project_fingerprint],
        env = environment,
        execution_requirements = {"block-network": "1"},
        mnemonic = "REBARCOMPILE",
        progress_message = "Compiling Erlang application {} with Rebar3".format(ctx.attr.app_name),
        toolchain = "//:toolchain_type",
        use_default_shell_env = False,
    )
    return [
        DefaultInfo(files = depset([output])),
        _RebarCompileInfo(
            fingerprint = fingerprint,
            project_fingerprint = project_fingerprint,
        ),
    ]

_rebar_compile = rule(
    implementation = _rebar_compile_impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "priv": attr.label_list(allow_files = True),
        "include": attr.label_list(allow_files = True),
        "compile_deps": attr.label_list(providers = [ErlangAppInfo]),
        "runtime_deps": attr.label_list(providers = [ErlangAppInfo]),
        "type_deps": attr.label_list(providers = [ErlangAppInfo]),
        "rebar_config": attr.label(mandatory = True, allow_single_file = True),
        "rebar3": attr.label(mandatory = True, allow_single_file = True, cfg = "exec"),
    },
    toolchains = ["//:toolchain_type"],
)

def _rebar_library_info_impl(ctx):
    roots = ctx.attr.compile[DefaultInfo].files.to_list()
    runfiles = ctx.runfiles(files = roots)
    for dep in ctx.attr.runtime_deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    compile_deps = compile_depset(ctx.attr.compile_deps + ctx.attr.type_deps + ctx.attr.runtime_deps)
    runtime_deps = runtime_depset(ctx.attr.runtime_deps)
    type_deps = type_depset(ctx.attr.type_deps + ctx.attr.runtime_deps)
    project_files = ctx.files.srcs + ctx.files.priv + ctx.files.include + [ctx.file.rebar_config]
    project_entries = _project_entries(ctx, project_files)

    return [
        DefaultInfo(files = depset(roots), runfiles = runfiles),
        ErlangAppInfo(
            app_name = ctx.attr.app_name,
            beam = roots,
            build_roots = [root.path for root in roots],
            build_roots_short_path = [root.short_path for root in roots],
            compile_deps = compile_deps,
            compile_fingerprint = ctx.attr.compile[_RebarCompileInfo].fingerprint,
            lib_dirs = [path_join(root.path, "default", "lib") for root in roots],
            lib_dirs_short_path = [path_join(root.short_path, "default", "lib") for root in roots],
            deps = runtime_deps,
            direct_compile_deps = ctx.attr.compile_deps,
            direct_deps = ctx.attr.runtime_deps,
            direct_runtime_deps = ctx.attr.runtime_deps,
            direct_type_deps = ctx.attr.type_deps,
            extra_apps = [],
            include = ctx.files.include,
            license_files = [],
            priv = ctx.files.priv,
            project_entries = project_entries,
            project_files = project_files,
            project_fingerprint = ctx.attr.compile[_RebarCompileInfo].project_fingerprint,
            project_root_short_path = ctx.file.rebar_config.short_path.rsplit("/", 1)[0] if "/" in ctx.file.rebar_config.short_path else "",
            runtime_deps = runtime_deps,
            type_deps = type_deps,
            srcs = ctx.files.srcs,
        ),
    ]

_rebar_library_info = rule(
    implementation = _rebar_library_info_impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "compile": attr.label(mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "priv": attr.label_list(allow_files = True),
        "include": attr.label_list(allow_files = True),
        "compile_deps": attr.label_list(providers = [ErlangAppInfo]),
        "runtime_deps": attr.label_list(providers = [ErlangAppInfo]),
        "type_deps": attr.label_list(providers = [ErlangAppInfo]),
        "rebar_config": attr.label(mandatory = True, allow_single_file = True),
    },
)

def _rebar_library_impl(name, visibility, deps, **kwargs):
    common_keys = [
        "compatible_with",
        "exec_compatible_with",
        "features",
        "tags",
        "target_compatible_with",
        "testonly",
    ]
    common = {key: value for key, value in kwargs.items() if key in common_keys}
    runtime_deps = kwargs["runtime_deps"] + deps
    _rebar_compile(
        name = name + "_compile",
        app_name = kwargs["app_name"],
        compile_deps = kwargs["compile_deps"],
        include = kwargs["include"],
        priv = kwargs["priv"],
        rebar3 = kwargs["rebar3"],
        rebar_config = kwargs["rebar_config"],
        runtime_deps = runtime_deps,
        type_deps = kwargs["type_deps"],
        srcs = kwargs["srcs"],
        visibility = ["//visibility:private"],
        **common
    )
    _rebar_library_info(
        name = name,
        app_name = kwargs["app_name"],
        compile = ":" + name + "_compile",
        compile_deps = kwargs["compile_deps"],
        include = kwargs["include"],
        priv = kwargs["priv"],
        rebar_config = kwargs["rebar_config"],
        runtime_deps = runtime_deps,
        type_deps = kwargs["type_deps"],
        srcs = kwargs["srcs"],
        visibility = visibility,
        **common
    )

rebar_library = macro(
    doc = "Compile one Rebar3-managed Erlang/OTP application from declared offline inputs.",
    inherit_attrs = _rebar_compile,
    attrs = {
        "compile_deps": attr.label_list(providers = [ErlangAppInfo], configurable = False),
        "deps": attr.label_list(providers = [ErlangAppInfo], configurable = False),
        "rebar3": attr.label(mandatory = True, allow_single_file = True, cfg = "exec"),
        "rebar_config": attr.label(mandatory = True, allow_single_file = True),
        "runtime_deps": attr.label_list(providers = [ErlangAppInfo], configurable = False),
        "type_deps": attr.label_list(providers = [ErlangAppInfo], configurable = False),
        "tags": attr.string_list(configurable = False),
    },
    implementation = _rebar_library_impl,
)
