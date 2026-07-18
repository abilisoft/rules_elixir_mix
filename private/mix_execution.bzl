"""Direct, shell-free Mix execution helpers."""

load("//private:beam_info.bzl", "ErlangAppInfo", "crypto_exec_inputs", "crypto_exec_tools", "erl_env_flags", "execution_root_path", "fips_erl_args", "flat_deps", "otp_runtime_env", "path_join", "runtime_path_erl_args", "test_erl_launcher")
load("//private:mix_info.bzl", "MixProjectInfo")

_MIX_EVAL = """
execution_root = File.cwd!()
resolve_input = fn resolve_input, source ->
  case File.lstat!(source).type do
    :symlink ->
      target = File.read_link!(source) |> Path.expand(Path.dirname(source))
      resolve_input.(resolve_input, target)
    _ -> source
  end
end
absolute_input = fn source ->
  source = Path.expand(to_string(source), execution_root)
  resolve_input.(resolve_input, source)
end
make_writable = fn make_writable, path ->
  {:ok, stat} = File.lstat(path)
  if stat.type != :symlink do
    mode = stat.mode |> Bitwise.band(0o777) |> Bitwise.bor(0o200)
    if stat.type == :directory do
      File.chmod!(path, Bitwise.bor(mode, 0o100))
      path |> File.ls!() |> Enum.each(&make_writable.(make_writable, Path.join(path, &1)))
    else
      File.chmod!(path, mode)
    end
  end
end
copy_input = fn copy_input, source, destination ->
  source = resolve_input.(resolve_input, source)
  case File.lstat!(source).type do
    :directory ->
      File.mkdir_p!(destination)
      source
      |> File.ls!()
      |> Enum.each(&copy_input.(copy_input, Path.join(source, &1), Path.join(destination, &1)))
    _ ->
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
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
fingerprint_source = fn fingerprint_source, source, relative ->
  source = resolve_input.(resolve_input, Path.expand(to_string(source), execution_root))
  stat = File.lstat!(source)
  mode = Bitwise.band(stat.mode, 0o777)
  case stat.type do
    :directory ->
      children =
        source
        |> File.ls!()
        |> Enum.sort()
        |> Enum.flat_map(fn child ->
          fingerprint_source.(
            fingerprint_source,
            Path.join(source, child),
            Path.join(to_string(relative), child)
          )
        end)
      [{to_string(relative), :directory, mode} | children]
    :regular ->
      content = File.read!(source)
      [{
        to_string(relative),
        :regular,
        mode,
        byte_size(content),
        :erlang.phash2(content, 4_294_967_296),
        :erlang.phash2({:rules_elixir_mix, content}, 4_294_967_296),
      }]
    :symlink ->
      [{to_string(relative), :symlink, mode, File.read_link!(source)}]
    type ->
      [{to_string(relative), type, mode}]
  end
end
project_dir = System.fetch_env!("RULES_ELIXIR_MIX_PROJECT_DIR")
if child_erl_aflags = System.get_env("RULES_ELIXIR_MIX_CHILD_ERL_AFLAGS") do
  System.put_env("ERL_AFLAGS", child_erl_aflags)
end
case System.get_env("RULES_ELIXIR_MIX_PROJECT_MANIFEST") do
  nil -> :ok
  manifest ->
    File.rm_rf!(project_dir)
    File.mkdir_p!(project_dir)
    {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
    Enum.each(entries, fn {source, relative} ->
      source = absolute_input.(source)
      destination = Path.join(project_dir, to_string(relative))
      File.mkdir_p!(Path.dirname(destination))
      copy_input.(copy_input, source, destination)
      make_writable.(make_writable, destination)
    end)
end
case System.get_env("RULES_ELIXIR_MIX_DEPS_MANIFEST") do
  nil -> :ok
  manifest ->
    deps_root = System.fetch_env!("MIX_DEPS_PATH")
    File.rm_rf!(deps_root)
    File.mkdir_p!(deps_root)
    {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
    Enum.each(entries, fn {source, relative} ->
      source = absolute_input.(source)
      destination = Path.join(deps_root, to_string(relative))
      File.mkdir_p!(Path.dirname(destination))
      copy_input.(copy_input, source, destination)
      make_writable.(make_writable, destination)
    end)
end
case System.get_env("RULES_ELIXIR_MIX_PRECOMPILED_NATIVE_MANIFEST") do
  nil -> :ok
  manifest ->
    cache = Path.expand(System.fetch_env!("ELIXIR_MAKE_CACHE_DIR"), execution_root)
    System.put_env("ELIXIR_MAKE_CACHE_DIR", cache)
    File.rm_rf!(cache)
    File.mkdir_p!(cache)
    {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
    Enum.each(entries, fn {source, basename} ->
      source = absolute_input.(source)
      destination = Path.join(cache, to_string(basename))
      File.cp!(source, destination)
      make_writable.(make_writable, destination)
    end)
end
# erlexec records ERL_ROOTDIR before this driver can replace the relocatable
# /proc/self/cwd marker with an absolute path. Keep that recorded VM root valid
# after entering the staged project by installing one action-local symlink at
# the same project-relative location. This is required by Mix.Release, which
# copies ERTS from :code.root_dir/0.
vm_root = :code.root_dir() |> to_string()
execution_marker = "/proc/self/cwd/"
vm_root_alias =
  if String.starts_with?(vm_root, execution_marker) do
    relative = String.replace_prefix(vm_root, execution_marker, "")
    stable_root = Path.join(project_dir, relative)
    expected_target = Path.join(execution_root, relative)
    File.mkdir_p!(Path.dirname(stable_root))
    case File.read_link(stable_root) do
      {:ok, ^expected_target} -> :ok
      {:error, :enoent} -> File.ln_s!(expected_target, stable_root)
      _ -> raise "project input collides with the action-local OTP root alias: #{relative}"
    end
    stable_root
  else
    nil
  end
File.cd!(project_dir)
try do
  if System.get_env("RULES_ELIXIR_MIX_FIPS_REQUIRED") == "true" do
    case Application.load(:crypto) do
      :ok -> :ok
      {:error, {:already_loaded, :crypto}} -> :ok
    end
    :ok = Application.put_env(:crypto, :fips_mode, true)
    {:ok, _} = Application.ensure_all_started(:crypto)
    :enabled = :crypto.info_fips()
    %{link_type: :static} = :crypto.info()
  end

  case System.get_env("RULES_ELIXIR_MIX_BUILD_MANIFEST") do
    nil -> :ok
    manifest ->
      {:ok, [links]} = :file.consult(String.to_charlist(manifest))
      Enum.each(links, fn {source, destination} ->
        source = absolute_input.(source)
        destination = Path.expand(to_string(destination), execution_root)
        File.mkdir_p!(Path.dirname(destination))
        File.rm_rf!(destination)
        copy_input.(copy_input, source, destination)
        make_writable.(make_writable, destination)
      end)
  end

  case System.get_env("RULES_ELIXIR_MIX_BUILD_CACHE_MANIFEST") do
    nil -> :ok
    manifest ->
      {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
      Enum.each(entries, fn {source, app} ->
        source = absolute_input.(source)
        destination = Path.join([
          System.fetch_env!("MIX_BUILD_ROOT"),
          System.fetch_env!("MIX_ENV"),
          "lib",
          to_string(app),
        ])
        File.mkdir_p!(Path.dirname(destination))
        File.rm_rf!(destination)
        copy_input.(copy_input, source, destination)
        make_writable.(make_writable, destination)
      end)
  end

  case System.get_env("RULES_ELIXIR_MIX_PRIV_MANIFEST") do
    nil -> :ok
    manifest ->
      {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
      root = Path.join([
        System.fetch_env!("RULES_ELIXIR_MIX_BUILD_ROOT"),
        System.fetch_env!("MIX_ENV"),
        "lib",
        System.fetch_env!("RULES_ELIXIR_MIX_APP"),
        "priv",
      ])
      Enum.each(entries, fn {source, relative} ->
        source = absolute_input.(source)
        destination = Path.join(root, to_string(relative))
        File.mkdir_p!(Path.dirname(destination))
        File.rm_rf!(destination)
        copy_input.(copy_input, source, destination)
        make_writable.(make_writable, destination)
      end)
  end

  case System.get_env("RULES_ELIXIR_MIX_INCLUDE_MANIFEST") do
    nil -> :ok
    manifest ->
      {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
      root = Path.join([
        System.fetch_env!("RULES_ELIXIR_MIX_BUILD_ROOT"),
        System.fetch_env!("MIX_ENV"),
        "lib",
        System.fetch_env!("RULES_ELIXIR_MIX_APP"),
        "include",
      ])
      Enum.each(entries, fn {source, relative} ->
        destination = Path.join(root, to_string(relative))
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(absolute_input.(source), destination)
        make_writable.(make_writable, destination)
      end)
  end

  if System.get_env("RULES_ELIXIR_MIX_PRELOAD_DEPS") == "true" do
    Mix.start()
    if System.get_env("RULES_ELIXIR_MIX_LOAD_HEX") == "true" do
      {:ok, _} = Application.ensure_all_started(:hex)
    end
    Code.compile_file(System.fetch_env!("RULES_ELIXIR_MIX_EXS"))
    # Bazel already resolved, built, and staged the exact dependency graph.
    # Test and analysis actions must not ask Mix/Hex to rediscover that graph:
    # doing so both duplicates analysis and makes an otherwise offline action
    # depend on the Hex SCM archive. Keep the project's remaining configuration
    # intact while making the Bazel-owned graph authoritative.
    if System.get_env("RULES_ELIXIR_MIX_BAZEL_DEPS") == "true" do
      Process.put(
        {:rules_elixir_mix, :project_deps},
        Mix.Project.config()[:deps] || []
      )
      Mix.ProjectStack.merge_config(deps: [])
    end
    Mix.Task.run("loadconfig")
    Mix.Task.run("loadpaths", [
      "--no-deps-check",
      "--no-listeners",
      "--no-prune-code-paths",
    ])
    System.put_env("RULES_ELIXIR_MIX_PROJECT_PRELOADED", "true")
  end

  if System.get_env("RULES_ELIXIR_MIX_RECOMPILE_FOR_COVERAGE") == "true" do
    # Elixir 1.20 records absolute source paths in BEAM debug information, so
    # coverage recompiles only the first-party application in the test
    # sandbox. Restore its declared dependency metadata before compiling: Mix
    # must write the correct runtime applications into the generated .app,
    # even though Bazel remains responsible for resolving and staging them.
    Mix.ProjectStack.merge_config(
      deps: Process.get({:rules_elixir_mix, :project_deps}, [])
    )
    app_root = Path.join([
      System.fetch_env!("MIX_BUILD_ROOT"),
      System.fetch_env!("MIX_ENV"),
      "lib",
      System.fetch_env!("RULES_ELIXIR_MIX_APP"),
    ])
    File.rm_rf!(app_root)
    Mix.Task.reenable("compile")
    Mix.Task.run("compile", [
      "--force",
      "--no-archives-check",
      "--no-deps-check",
      "--no-prune-code-paths",
      "--no-protocol-consolidation",
    ])
  end

  # Some post-compilation tasks invoke `compile` internally. Run the task once
  # with compilation disabled and code-path pruning disabled; the task's own
  # call then observes Mix's normal once-per-VM semantics and cannot rebuild
  # the already declared Bazel application or discard declared tool paths.
  if System.get_env("RULES_ELIXIR_MIX_PREPARE_COMPILED_PROJECT") == "true" do
    Mix.Task.run("compile", [
      "--no-archives-check",
      "--no-compile",
      "--no-deps-check",
      "--no-prune-code-paths",
    ])
    Enum.each([:eex, :logger], fn application ->
      case Application.load(application) do
        :ok -> :ok
        {:error, {:already_loaded, ^application}} -> :ok
      end
      application
      |> Application.spec(:modules)
      |> Enum.each(&Code.ensure_loaded!/1)
    end)
  end

  args = Enum.map(System.argv(), fn
    "__RULES_ELIXIR_MIX_OUTPUT__" ->
      System.fetch_env!("RULES_ELIXIR_MIX_OUTPUT") |> Path.expand(execution_root)
    argument -> argument
  end)
  {args, skip?} =
    if System.get_env("RULES_ELIXIR_MIX_SHARD_TESTS") == "true" do
      index = String.to_integer(System.get_env("TEST_SHARD_INDEX") || "0")
      total = String.to_integer(System.get_env("TEST_TOTAL_SHARDS") || "1")
      tests = Enum.filter(args, &String.ends_with?(&1, "_test.exs"))
      selected = Enum.filter(tests, &(rem(:erlang.crc32(&1), total) == index))
      selected_set = MapSet.new(selected)
      sharded = Enum.reject(args, &(String.ends_with?(&1, "_test.exs") and not MapSet.member?(selected_set, &1)))
      {sharded, tests != [] and selected == []}
    else
      {args, false}
    end

  if status = System.get_env("TEST_SHARD_STATUS_FILE"), do: File.write!(status, "")
  build_root = System.fetch_env!("MIX_BUILD_ROOT")
  if File.dir?(build_root), do: make_writable.(make_writable, build_root)
  mix_exs =
    if System.get_env("RULES_ELIXIR_MIX_PROJECT_PRELOADED") == "true" do
      nil
    else
      System.fetch_env!("RULES_ELIXIR_MIX_EXS")
    end
  result = if skip?, do: :ok, else: Mix.CLI.main(args, mix_exs)
  if System.get_env("RULES_ELIXIR_MIX_VERIFY_APP") == "true" do
    app = System.fetch_env!("RULES_ELIXIR_MIX_APP")
    app_file = Path.join([
      System.fetch_env!("RULES_ELIXIR_MIX_BUILD_ROOT"),
      System.fetch_env!("MIX_ENV"),
      "lib",
      app,
      "ebin",
      app <> ".app",
    ])
    if not File.regular?(app_file), do: raise("Mix did not emit expected OTP application #{app}: #{app_file}")
    {:ok, [{:application, emitted, _properties}]} = :file.consult(String.to_charlist(app_file))
    if Atom.to_string(emitted) != app do
      raise("Mix emitted OTP application #{inspect(emitted)} but Bazel target declares #{inspect(app)}")
    end
  end
  if System.get_env("RULES_ELIXIR_MIX_REMOVE_STAGED_DEPS") == "true" do
    manifest = System.fetch_env!("RULES_ELIXIR_MIX_BUILD_CACHE_MANIFEST")
    {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
    Enum.each(entries, fn {_source, app} ->
      File.rm_rf!(Path.join([
        System.fetch_env!("MIX_BUILD_ROOT"),
        System.fetch_env!("MIX_ENV"),
        "lib",
        to_string(app),
      ]))
    end)
  end
  case System.get_env("RULES_ELIXIR_MIX_COMPILE_FINGERPRINT") do
    nil -> :ok
    fingerprint ->
      app_root = Path.join([
        System.fetch_env!("RULES_ELIXIR_MIX_BUILD_ROOT"),
        System.fetch_env!("MIX_ENV"),
        "lib",
        System.fetch_env!("RULES_ELIXIR_MIX_APP"),
      ])
      entries = fingerprint_tree.(app_root)
      fingerprint = Path.expand(fingerprint, execution_root)
      File.mkdir_p!(Path.dirname(fingerprint))
      File.write!(fingerprint, :erlang.term_to_binary(entries, [:deterministic]))
  end
  case System.get_env("RULES_ELIXIR_MIX_PROJECT_FINGERPRINT") do
    nil -> :ok
    fingerprint ->
      manifest = System.fetch_env!("RULES_ELIXIR_MIX_PROJECT_MANIFEST")
      {:ok, [entries]} = :file.consult(String.to_charlist(manifest))
      entries =
        entries
        |> Enum.flat_map(fn {source, relative} ->
          fingerprint_source.(fingerprint_source, source, relative)
        end)
        |> Enum.sort()
      fingerprint = Path.expand(fingerprint, execution_root)
      File.mkdir_p!(Path.dirname(fingerprint))
      File.write!(fingerprint, :erlang.term_to_binary(entries, [:deterministic]))
  end
  case System.get_env("RULES_ELIXIR_MIX_FIPS_RELEASE_ROOT") do
    nil -> :ok
    release_root ->
      configs = Path.wildcard(Path.join([release_root, "releases", "*", "sys.config"]))
      if configs == [], do: raise("FIPS release has no generated sys.config")
      Enum.each(configs, fn config_file ->
        {:ok, [config]} = :file.consult(String.to_charlist(config_file))
        crypto = config |> Keyword.get(:crypto, []) |> Keyword.put(:fips_mode, true)
        merged = Keyword.put(config, :crypto, crypto)
        File.write!(config_file, :io_lib.format(~c"~tp.~n", [merged]))
      end)
  end


  case System.get_env("RULES_ELIXIR_MIX_CRYPTO_RELEASE_MANIFEST") do
    nil -> :ok
    manifest ->
      release_root = System.fetch_env!("RULES_ELIXIR_MIX_RELEASE_ROOT")
      sdk_root = Path.join(release_root, ".rules_elixir_mix/crypto_sdk")
      File.rm_rf!(sdk_root)
      File.mkdir_p!(sdk_root)
      {:ok, [entries]} = :file.consult(String.to_charlist(manifest))

      Enum.each(entries, fn {source, relative} ->
        source = absolute_input.(source)
        relative = to_string(relative)
        destination = if relative == ".", do: sdk_root, else: Path.join(sdk_root, relative)
        File.mkdir_p!(Path.dirname(destination))
        File.rm_rf!(destination)
        copy_input.(copy_input, source, destination)
        make_writable.(make_writable, destination)
      end)

      state_root = Path.join(release_root, ".rules_elixir_mix")
      File.cp!(
        System.fetch_env!("RULES_ELIXIR_MIX_CRYPTO_ACTIVATION_CONFIG"),
        Path.join(state_root, "crypto_activation.config")
      )
      make_writable.(make_writable, Path.join(state_root, "crypto_activation.config"))
      hook = File.read!(System.fetch_env!("RULES_ELIXIR_MIX_CRYPTO_RELEASE_HOOK"))
      runtime_configs = Path.wildcard(Path.join([release_root, "releases", "*", "runtime.exs"]))
      if runtime_configs == [], do: raise("provider-backed crypto release has no generated runtime.exs")

      Enum.each(runtime_configs, fn runtime_config ->
        existing = File.read!(runtime_config)
        File.write!(runtime_config, [hook, "\n", existing])
      end)
  end
  case System.get_env("RULES_ELIXIR_MIX_FIPS_RELEASE_ENFORCEMENT") do
    nil -> :ok
    enforcement_file ->
      release_root = System.fetch_env!("RULES_ELIXIR_MIX_FIPS_RELEASE_ROOT")
      enforcement = File.read!(enforcement_file)
      Path.wildcard(Path.join([release_root, "releases", "*", "runtime.exs"]))
      |> Enum.each(fn runtime_config ->
        File.write!(runtime_config, [File.read!(runtime_config), "\n", enforcement])
      end)
  end
  if System.get_env("RULES_ELIXIR_MIX_REMOVE_BUILD_ROOT") == "true" do
    File.rm_rf!(System.fetch_env!("MIX_BUILD_ROOT"))
  end
  case {System.get_env("RULES_ELIXIR_MIX_COVERAGE_SOURCE"), System.get_env("COVERAGE_OUTPUT_FILE")} do
    {nil, _} -> :ok
    {_, nil} -> :ok
    {source, destination} ->
      source = Path.expand(source, project_dir)
      if not File.regular?(source), do: raise("coverage task did not emit #{source}")
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
  end
  result
after
  File.rm_rf!(System.fetch_env!("RULES_ELIXIR_MIX_STATE_DIR"))
  if System.get_env("RULES_ELIXIR_MIX_LOCAL_STATE") && vm_root_alias do
    File.rm!(vm_root_alias)
  end
end
"""

MIX_EVAL = _MIX_EVAL

_POSTGRES_EVAL = """
T = os:getenv("TEST_TMPDIR"),
D = filename:join(T, "postgres"),
S = filename:join(T, "postgres_socket"),
ok = filelib:ensure_dir(filename:join(D, ".keep")),
ok = filelib:ensure_dir(filename:join(S, ".keep")),
Run = fun(Executable, Arguments) ->
  Port = open_port({spawn_executable, filename:absname(Executable)}, [binary, exit_status, stderr_to_stdout, use_stdio, {args, Arguments}]),
  Await = fun Loop(Chunks) ->
    receive
      {Port, {data, Data}} -> Loop([Data | Chunks]);
      {Port, {exit_status, 0}} -> ok;
      {Port, {exit_status, Status}} -> erlang:error({postgres_command_failed, Executable, Status, lists:reverse(Chunks)})
    end
  end,
  Await([])
end,
ok = Run(os:getenv("RULES_ELIXIR_MIX_INITDB"), ["--auth=trust", "--encoding=UTF8", "--no-locale", "--no-sync", "--username=postgres", "-D", D]),
{ok, Probe} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
{ok, {_, PortNumber}} = inet:sockname(Probe),
ok = gen_tcp:close(Probe),
Parent = self(),
Postgres = os:getenv("RULES_ELIXIR_MIX_POSTGRES"),
spawn_link(fun() ->
  ServerPort = open_port({spawn_executable, filename:absname(Postgres)}, [binary, exit_status, stderr_to_stdout, use_stdio, {args, ["-D", D, "-h", "127.0.0.1", "-k", S, "-p", integer_to_list(PortNumber), "-c", "fsync=off", "-c", "full_page_writes=off", "-c", "synchronous_commit=off"]}]),
  Parent ! postgres_port_started,
  Drain = fun Loop() ->
    receive
      {ServerPort, {data, Data}} -> io:put_chars(standard_error, Data), Loop();
      {ServerPort, {exit_status, Status}} -> erlang:error({postgres_server_failed, Status})
    end
  end,
  Drain()
end),
receive postgres_port_started -> ok after 5000 -> erlang:error(postgres_start_timeout) end,
Wait = fun Loop(0) -> erlang:error(postgres_readiness_timeout);
           Loop(Attempts) ->
             case gen_tcp:connect({127,0,0,1}, PortNumber, [binary, {active, false}], 100) of
               {ok, Socket} -> gen_tcp:close(Socket);
               {error, _} -> receive after 50 -> Loop(Attempts - 1) end
             end
       end,
ok = Wait(200),
Database = os:getenv("RULES_ELIXIR_MIX_POSTGRES_DATABASE"),
ok = Run(os:getenv("RULES_ELIXIR_MIX_CREATEDB"), ["--host=127.0.0.1", "--port=" ++ integer_to_list(PortNumber), "--username=postgres", Database]),
true = os:putenv("DATABASE_URL", "ecto://postgres@127.0.0.1:" ++ integer_to_list(PortNumber) ++ "/" ++ Database),
ok.
"""

def _toolchain(ctx):
    return ctx.toolchains["//:toolchain_type"]

def _project_relative_path(file, project_root):
    short_path = file.short_path
    prefix = project_root.rstrip("/") + "/" if project_root else ""
    if prefix and short_path.startswith(prefix):
        relative = short_path[len(prefix):]
    elif not prefix and not short_path.startswith("../"):
        relative = short_path
    else:
        return None
    if not relative or relative.startswith("/") or "\\" in relative or any([part in ["", ".", ".."] for part in relative.split("/")]):
        fail("project input {} has unsafe project-relative path '{}'".format(file, relative))
    return relative

def _validate_project_destination(relative, owner):
    if not relative or relative.startswith("/") or "\\" in relative or any([part in ["", ".", ".."] for part in relative.split("/")]):
        fail("{} has unsafe project-relative destination '{}'".format(owner, relative))

def _project_manifest(ctx, mix_config, project_inputs, project_entries = [], short_path = False):
    project_root = mix_config.short_path.rsplit("/", 1)[0] if "/" in mix_config.short_path else ""
    by_destination = {}
    entries = []
    explicitly_mapped = {}
    for entry in project_entries:
        _validate_project_destination(entry.destination, entry.source)
        if entry.destination in by_destination and by_destination[entry.destination].path != entry.source.path:
            fail("project inputs {} and {} both map to '{}'".format(by_destination[entry.destination], entry.source, entry.destination))
        if entry.destination not in by_destination:
            by_destination[entry.destination] = entry.source
            entries.append((entry.source.short_path if short_path else entry.source.path, entry.destination))
        explicitly_mapped[entry.source.path] = True
    for file in project_inputs:
        if file.path in explicitly_mapped:
            continue
        relative = _project_relative_path(file, project_root)
        if relative == None:
            fail("project input {} is outside source root '{}' and requires elixir_generated_source with an explicit destination".format(file, project_root or "."))
        if relative in by_destination:
            if by_destination[relative].path != file.path:
                fail("project inputs {} and {} both map to '{}'".format(by_destination[relative], file, relative))
            continue
        by_destination[relative] = file
        entries.append((file.short_path if short_path else file.path, relative))
    if mix_config.basename not in by_destination:
        fail("mix_config {} must be included in project_inputs".format(mix_config))
    manifest = ctx.actions.declare_file(ctx.label.name + "_project_manifest")
    ctx.actions.write(
        manifest,
        "[{}].\n".format(", ".join([
            "{{{}, {}}}".format(_erl_string(source), _erl_string(relative))
            for source, relative in entries
        ])),
    )
    return manifest

def _dependency_manifest(ctx, deps, short_path = False):
    entries = []
    inputs = []
    destinations = {}
    seen_apps = {}
    for dep in deps:
        info = dep[ErlangAppInfo]
        if info.app_name in seen_apps:
            continue
        seen_apps[info.app_name] = True
        if info.project_entries:
            for entry in info.project_entries:
                file = entry.source
                relative = entry.destination
                _validate_project_destination(relative, file)
                destination = path_join(info.app_name, relative)
                if destination in destinations:
                    if destinations[destination].path != file.path:
                        fail("dependency project inputs {} and {} both map to '{}'".format(destinations[destination], file, destination))
                    continue
                destinations[destination] = file
                entries.append((struct(path = file.short_path if short_path else file.path), destination))
                inputs.append(file)
        else:
            lib_dirs = info.lib_dirs_short_path if short_path else info.lib_dirs
            if len(lib_dirs) != 1:
                fail("dependency {} must expose exactly one library directory".format(dep.label))
            entries.append((struct(path = path_join(lib_dirs[0], info.app_name)), info.app_name))
    manifest = ctx.actions.declare_file(ctx.label.name + "_deps_manifest")
    ctx.actions.write(
        manifest,
        "[{}].\n".format(", ".join([
            "{{{}, {}}}".format(_erl_string(source.path), _erl_string(relative))
            for source, relative in entries
        ])),
    )
    return manifest, inputs

def _app_lib_dirs(targets, short_path = False):
    dirs = []
    for target in flat_deps(targets):
        info = target[ErlangAppInfo]
        values = info.lib_dirs_short_path if short_path else info.lib_dirs
        for value in values:
            if value not in dirs:
                dirs.append(value)
    return dirs

def _build_cache_manifest(ctx, targets, short_path = False):
    entries = []
    seen = {}
    for target in targets:
        info = target[ErlangAppInfo]
        if info.app_name in seen:
            continue
        seen[info.app_name] = True
        lib_dirs = info.lib_dirs_short_path if short_path else info.lib_dirs
        if len(lib_dirs) != 1:
            fail("application {} must expose exactly one library directory".format(target.label))
        entries.append((path_join(lib_dirs[0], info.app_name), info.app_name))
    manifest = ctx.actions.declare_file(ctx.label.name + "_build_cache_manifest")
    ctx.actions.write(
        manifest,
        "[{}].\n".format(", ".join([
            "{{{}, {}}}".format(_erl_string(source), _erl_string(app))
            for source, app in entries
        ])),
    )
    return manifest

def validate_user_env(user_env):
    """Reject caller overrides of hermetic runtime/build invariants.

    Args:
      user_env: Caller-supplied environment dictionary.
    """
    reserved_prefixes = ["DYLD_", "ELIXIR_MAKE_", "ERL_", "HEX_", "MIX_", "OPENSSL_", "RULES_ELIXIR_MIX_"]
    reserved = ["BASH_ENV", "BINDIR", "EMU", "FIPS_MODULE_CONF", "HOME", "LANG", "LC_ALL", "LD_LIBRARY_PATH", "LD_PRELOAD", "PATH", "PROGNAME", "ROOTDIR", "SHELL", "SOURCE_DATE_EPOCH", "TEMP", "TMP", "TMPDIR", "TZ"]
    for key in user_env:
        if key in reserved or any([key.startswith(prefix) for prefix in reserved_prefixes]):
            fail("environment variable '{}' is owned by rules_elixir_mix and cannot be overridden".format(key))

def mix_action_env(ctx, mix_env, build_root, deps, internal_extra = {}, user_extra = {}):
    """Return a complete, strict environment for a Mix build action.

    Args:
      ctx: Rule context with the combined BEAM toolchain.
      mix_env: Mix environment name.
      build_root: Declared output build-root path.
      deps: Direct Mix application dependencies.
      internal_extra: Rule-owned explicit environment entries.
      user_extra: Caller environment entries, excluding rule-owned namespaces.

    Returns:
      Environment dictionary with no host-environment inheritance.
    """
    toolchain = _toolchain(ctx)
    work_root = build_root + ".rules_elixir_mix_state"
    validate_user_env(user_extra)
    env = otp_runtime_env(toolchain.otpinfo)
    env.update({
        "ERL_COMPILER_OPTIONS": "deterministic",
        "ERL_LIBS": ":".join(
            [path_join(toolchain.elixirinfo.elixir_home, "lib")] +
            _app_lib_dirs(deps),
        ),
        "ELIXIR_MAKE_CACHE_DIR": path_join(work_root, "elixir_make"),
        "HEX_HOME": path_join(work_root, "hex"),
        "HEX_OFFLINE": "true",
        "HOME": path_join(work_root, "home"),
        "LANG": "C",
        "LC_ALL": "C",
        "MIX_ARCHIVES": path_join(work_root, "mix", "archives"),
        "MIX_BUILD_PATH": path_join(build_root, mix_env),
        "MIX_BUILD_ROOT": build_root,
        "MIX_DEPS_PATH": path_join(work_root, "deps"),
        "MIX_ENV": mix_env,
        "MIX_HOME": path_join(work_root, "mix"),
        "MIX_OS_CONCURRENCY_LOCK": "false",
        "PATH": toolchain.otpinfo.erts_bin,
        "SOURCE_DATE_EPOCH": "946684800",
        "TMPDIR": path_join(work_root, "tmp"),
        "TZ": "UTC",
    })
    if toolchain.otpinfo.fips == "required":
        env["ERL_AFLAGS"] = erl_env_flags(runtime_path_erl_args() + ["-crypto", "fips_mode", "true"])
        env["RULES_ELIXIR_MIX_FIPS_REQUIRED"] = "true"
    env.update(user_extra)
    env.update(internal_extra)
    return env

def run_mix_action(
        ctx,
        task,
        task_args,
        mix_config,
        mix_env,
        build_root,
        deps,
        inputs,
        project_inputs,
        outputs,
        project_entries = [],
        internal_env = {},
        user_env = {},
        stage_build_cache = True,
        action_inputs = None,
        action_tools = [],
        mnemonic = "MIX"):
    """Invoke Mix through erl and the declared Elixir BEAM runtime.

    Args:
      ctx: Rule context used to register the action.
      task: Mix task name.
      task_args: Arguments passed to the Mix task.
      mix_config: Declared `mix.exs` file.
      mix_env: Mix environment name.
      build_root: Declared output build-root path.
      deps: Direct Mix application dependencies.
      inputs: Direct source and project inputs.
      project_inputs: Inputs staged at their logical paths below the writable project root.
      outputs: Declared action outputs.
      project_entries: Explicit stable logical mappings for generated project inputs.
      internal_env: Additional rule-owned environment entries.
      user_env: Caller environment entries, validated against reserved keys.
      stage_build_cache: Whether compiled dependencies are copied into MIX_BUILD_ROOT.
      action_inputs: Optional depset of extra declared inputs for selective compilers.
      action_tools: Optional FilesToRunProvider list for selective compilers.
      mnemonic: Bazel action mnemonic.
    """
    toolchain = _toolchain(ctx)
    project_manifest = _project_manifest(ctx, mix_config, project_inputs, project_entries = project_entries)
    dependency_manifest, dependency_inputs = _dependency_manifest(ctx, deps)
    build_cache_manifest = _build_cache_manifest(ctx, flat_deps(deps)) if stage_build_cache else None
    state_dir = build_root + ".rules_elixir_mix_state"
    internal = dict(internal_env)
    internal.update({
        "RULES_ELIXIR_MIX_PROJECT_MANIFEST": project_manifest.path,
        "RULES_ELIXIR_MIX_DEPS_MANIFEST": dependency_manifest.path,
    })
    if build_cache_manifest:
        internal.update({
            "RULES_ELIXIR_MIX_BUILD_CACHE_MANIFEST": build_cache_manifest.path,
            "RULES_ELIXIR_MIX_REMOVE_STAGED_DEPS": "true",
        })
    env = mix_action_env(ctx, mix_env, build_root, deps, internal, user_env)
    env.update({
        "RULES_ELIXIR_MIX_EXS": mix_config.basename,
        "RULES_ELIXIR_MIX_PROJECT_DIR": path_join(state_dir, "project"),
        "RULES_ELIXIR_MIX_STATE_DIR": state_dir,
    })

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
        _MIX_EVAL,
        "--",
        task,
    ])
    args.add_all(task_args)

    transitive_inputs = [toolchain.runtime_files, crypto_exec_inputs(toolchain.otpinfo)] + [
        dep[DefaultInfo].files
        for dep in flat_deps(deps)
    ]
    if action_inputs != None:
        transitive_inputs.append(action_inputs)

    ctx.actions.run(
        executable = toolchain.otpinfo.erlexec,
        arguments = [args],
        inputs = depset(
            direct = inputs + dependency_inputs + [project_manifest, dependency_manifest] + ([build_cache_manifest] if build_cache_manifest else []),
            transitive = transitive_inputs,
        ),
        tools = crypto_exec_tools(toolchain.otpinfo) + action_tools,
        outputs = outputs,
        env = env,
        execution_requirements = {"block-network": "1"},
        mnemonic = mnemonic,
        toolchain = "//:toolchain_type",
        use_default_shell_env = False,
    )

def runfile_path_from_project(mix_info, file):
    """Return a test input path relative to the staged Mix project.

    Args:
      mix_info: Mix project provider containing the project root.
      file: Source file whose project-relative path is required.

    Returns:
      The source path relative to the staged Mix project.
    """
    root = mix_info.mix_config.short_path.rsplit("/", 1)[0] if "/" in mix_info.mix_config.short_path else ""
    relative = _project_relative_path(file, root)
    if relative == None:
        fail("test input {} must be below Mix project root '{}'".format(file, root or "."))
    return relative

def _runfile_path_from_initial_cwd(file):
    return execution_root_path(file.short_path)

def expand_runtime_env(ctx, targets):
    """Expand $(location) values to paths valid after entering the package.

    Args:
      ctx: Test rule context containing the environment attribute.
      targets: Data and tool targets available for location expansion.

    Returns:
      Expanded environment dictionary.
    """
    result = {}
    for key, value in ctx.attr.env.items():
        expanded = ctx.expand_location(value, targets)
        for target in targets:
            if DefaultInfo not in target:
                continue
            for file in target[DefaultInfo].files.to_list():
                expanded = expanded.replace(file.path, _runfile_path_from_initial_cwd(file))
        result[key] = expanded
    return result

def _erl_string(value):
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))

def _postgres_runtime(ctx):
    if not hasattr(ctx.attr, "postgres") or not ctx.attr.postgres:
        return [], {}, []
    if not ctx.attr.initdb or not ctx.attr.createdb:
        fail("postgres tests require postgres, initdb, and createdb executables")
    database = ctx.attr.postgres_database
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
    if not database or any([database[index] not in allowed for index in range(len(database))]):
        fail("postgres_database must contain only letters, digits, and underscores")
    if "DATABASE_URL" in ctx.attr.env:
        fail("DATABASE_URL is owned by the declared Postgres test environment")
    targets = [ctx.attr.postgres, ctx.attr.initdb, ctx.attr.createdb]
    environment = {
        "RULES_ELIXIR_MIX_CREATEDB": _runfile_path_from_initial_cwd(ctx.executable.createdb),
        "RULES_ELIXIR_MIX_INITDB": _runfile_path_from_initial_cwd(ctx.executable.initdb),
        "RULES_ELIXIR_MIX_POSTGRES": _runfile_path_from_initial_cwd(ctx.executable.postgres),
        "RULES_ELIXIR_MIX_POSTGRES_DATABASE": database,
    }
    return ["-eval", _POSTGRES_EVAL], environment, targets

def _stage_expression():
    """Generate Erlang file operations that stage cached apps in TEST_TMPDIR."""
    statements = [
        'T=os:getenv("TEST_TMPDIR")',
        'B=filename:join(T,"_build")',
        'os:putenv("HOME",T)',
        'os:putenv("HEX_HOME",filename:join(T,"hex"))',
        'os:putenv("MIX_ARCHIVES",filename:join([T,"mix","archives"]))',
        'os:putenv("MIX_BUILD_PATH",filename:join([B,os:getenv("MIX_ENV")]))',
        'os:putenv("MIX_BUILD_ROOT",B)',
        'os:putenv("MIX_DEPS_PATH",filename:join(T,"deps"))',
        'os:putenv("MIX_HOME",filename:join(T,"mix"))',
        'os:putenv("RULES_ELIXIR_MIX_PROJECT_DIR",filename:join(T,"project"))',
        'os:putenv("RULES_ELIXIR_MIX_STATE_DIR",filename:join(T,".rules_elixir_mix_state"))',
        'case os:getenv("RULES_ELIXIR_MIX_CHILD_ERL_AFLAGS") of false->ok;V->os:putenv("ERL_AFLAGS",V) end',
    ]
    return "begin " + ",".join(statements + ["ok"]) + " end."

def mix_test_result(ctx, task, task_args, srcs, data, tools):
    """Return a shell-free Bazel test that enters Mix through erl/elixir.

    Args:
      ctx: Test rule context.
      task: Mix task name.
      task_args: Arguments passed to the Mix task.
      srcs: Test and analysis source runfiles.
      data: Runtime data targets.
      tools: Execution-configured tool targets.

    Returns:
      DefaultInfo and RunEnvironmentInfo for the test executable.
    """
    toolchain = _toolchain(ctx)
    lib_info = ctx.attr.lib[ErlangAppInfo]
    mix_info = ctx.attr.lib[MixProjectInfo]
    postgres_args, postgres_environment, postgres_targets = _postgres_runtime(ctx)
    targets = data + tools + postgres_targets

    args = [task] + task_args

    # Analysis/test tasks may intentionally live in compile-only dependencies
    # (Credo, Sobelow, Dialyxir, test adapters). Stage the complete compile
    # closure without propagating those tools from the library at runtime.
    dependency_targets = (
        lib_info.runtime_deps.to_list() if task == "test" else lib_info.compile_deps.to_list()
    )
    app_targets = [ctx.attr.lib] + dependency_targets
    staged_targets = dependency_targets if task == "compile" else app_targets
    build_cache_manifest = _build_cache_manifest(ctx, staged_targets, short_path = True)
    dependency_manifest, dependency_inputs = _dependency_manifest(ctx, dependency_targets, short_path = True)
    project_inputs = mix_info.project_files.to_list() + srcs + ctx.files.config
    project_manifest = _project_manifest(
        ctx,
        mix_info.mix_config,
        project_inputs,
        project_entries = mix_info.project_entries,
        short_path = True,
    )
    erl_args = runtime_path_erl_args() + [
        "-noshell",
        "+fnu",
    ] + fips_erl_args(toolchain.otpinfo, runfiles = True) + [
        "-eval",
        _stage_expression(),
    ] + postgres_args + [
        "-s",
        "elixir",
        "start_cli",
        "-extra",
        "-e",
        _MIX_EVAL,
        "--",
    ] + args
    child_erl_aflags = erl_env_flags(runtime_path_erl_args() + (["-crypto", "fips_mode", "true"] if toolchain.otpinfo.fips == "required" else []))

    erl_lib_targets = dependency_targets if task == "compile" else app_targets
    erl_libs = [path_join(toolchain.elixirinfo.elixir_home_short_path, "lib")]
    erl_libs.extend(_app_lib_dirs(erl_lib_targets, short_path = True))

    environment = otp_runtime_env(toolchain.otpinfo, runfiles = True)
    environment.update({
        "ERL_AFLAGS": erl_env_flags(erl_args),
        "ERL_LIBS": ":".join(erl_libs),
        "HEX_OFFLINE": "true",
        "HOME": ".",
        "LANG": "C",
        "LC_ALL": "C",
        "MIX_ENV": mix_info.mix_env,
        "MIX_EXS": mix_info.mix_config.basename,
        "MIX_OS_CONCURRENCY_LOCK": "false",
        "RULES_ELIXIR_MIX_EXS": mix_info.mix_config.basename,
        "RULES_ELIXIR_MIX_BAZEL_DEPS": "true",
        "RULES_ELIXIR_MIX_PRELOAD_DEPS": "true",
        "RULES_ELIXIR_MIX_BUILD_CACHE_MANIFEST": _runfile_path_from_initial_cwd(build_cache_manifest),
        "RULES_ELIXIR_MIX_CHILD_ERL_AFLAGS": child_erl_aflags,
        "RULES_ELIXIR_MIX_DEPS_MANIFEST": _runfile_path_from_initial_cwd(dependency_manifest),
        "RULES_ELIXIR_MIX_APP": lib_info.app_name,
        "RULES_ELIXIR_MIX_PROJECT_MANIFEST": _runfile_path_from_initial_cwd(project_manifest),
        "SOURCE_DATE_EPOCH": "946684800",
        "TZ": "UTC",
    })
    if toolchain.otpinfo.fips == "required":
        environment["RULES_ELIXIR_MIX_FIPS_REQUIRED"] = "true"
    if task == "test":
        environment["RULES_ELIXIR_MIX_SHARD_TESTS"] = "true"
    if hasattr(ctx.attr, "recompile_for_coverage") and ctx.attr.recompile_for_coverage:
        environment["RULES_ELIXIR_MIX_RECOMPILE_FOR_COVERAGE"] = "true"
    if hasattr(ctx.attr, "coverage_output") and ctx.attr.coverage_output:
        environment["RULES_ELIXIR_MIX_COVERAGE_SOURCE"] = ctx.attr.coverage_output
    user_environment = expand_runtime_env(ctx, targets)
    validate_user_env(user_environment)
    environment.update(user_environment)
    environment.update(postgres_environment)

    runfiles = ctx.runfiles(
        files = srcs + ctx.files.config + ctx.files.data + ctx.files.tools + mix_info.project_files.to_list() + dependency_inputs + [build_cache_manifest, dependency_manifest, project_manifest],
        transitive_files = toolchain.runtime_files,
    ).merge(ctx.attr.lib[DefaultInfo].default_runfiles)
    for app in app_targets:
        runfiles = runfiles.merge(app[DefaultInfo].default_runfiles)
    for target in targets:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = test_erl_launcher(ctx, toolchain.otpinfo), runfiles = runfiles),
        RunEnvironmentInfo(environment = environment),
    ]
