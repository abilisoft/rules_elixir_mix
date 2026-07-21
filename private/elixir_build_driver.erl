%% Shell-free action driver for Elixir's upstream Makefile build.
-module(elixir_build_driver).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([ConfigPath, ExecutionRoot0]) ->
    ExecutionRoot = filename:absname(ExecutionRoot0),
    {ok, [Config]} = file:consult(ConfigPath),
    Output = absolute_build_path(maps:get(output, Config), ExecutionRoot),
    Work = Output ++ ".work",
    Source = filename:join(Work, "source"),
    Tools = filename:join(Work, "tools"),
    ok = remove(Work),
    ok = remove(Output),
    ok = ensure_directory(Source),
    ok = ensure_directory(Tools),
    copy_sources(maps:get(sources, Config), ExecutionRoot, Source),
    ok = bind_upstream_scripts_to_declared_shell(Source),
    Version = maps:get(version, Config),
    {ok, SourceVersion0} = file:read_file(filename:join(Source, "VERSION")),
    Version = string:trim(binary_to_list(SourceVersion0)),
    Erl = absolute_build_path(maps:get(erlexec, Config), ExecutionRoot),
    ok = file:make_symlink(Erl, filename:join(Tools, "erl")),
    Environment0 = maps:get(environment, Config),
    Environment1 = maps:map(fun(_Key, Value) -> expand_path(Value, ExecutionRoot) end, Environment0),
    Environment = inherit_declared_environment(
        Environment1,
        maps:get(inherited_sdk_environment, Config)
    ),
    ErlAFlags = expand_runtime_value(maps:get(erl_aflags, Config), ExecutionRoot),
    BuildEnvironment = Environment#{
        "ERL_COMPILER_OPTIONS" => "deterministic",
        "ERL_AFLAGS" => ErlAFlags,
        "ERLC_EMULATOR" => filename:join(Tools, "erl"),
        "ELIXIR_ERL_OPTIONS" => "+fnu",
        "HOME" => filename:join(Work, "home"),
        "LANG" => "C",
        "LC_ALL" => "C",
        "PATH" => Tools ++ ":" ++ maps:get("PATH", Environment),
        "SOURCE_DATE_EPOCH" => "946684800",
        "TMPDIR" => filename:join(Work, "tmp"),
        "TZ" => "UTC"
    },
    ok = ensure_directory(maps:get("HOME", BuildEnvironment)),
    ok = ensure_directory(maps:get("TMPDIR", BuildEnvironment)),
    Jobs = integer_to_list(maps:get(jobs, Config)),
    MakeShell = "SHELL=" ++ maps:get("SHELL", BuildEnvironment),
    GenerateApp = "GENERATE_APP=" ++ absolute_build_path(maps:get(escript, Config), ExecutionRoot) ++ " " ++
        filename:join([Source, "lib", "elixir", "scripts", "generate_app.escript"]),
    %% Elixir's Makefile defines BINDIR=bin. Because BINDIR also belongs to
    %% erlexec, GNU Make would otherwise export the project value to erlc/erl
    %% and make the VM search for bin/beam.smp.
    OtpBindir = "BINDIR=" ++ maps:get("BINDIR", BuildEnvironment),
    StableSource = "/rules_elixir_mix/sources/elixir-" ++ Version,
    %% Elixir's upstream default target builds its Erlang bootstrap modules
    %% before stdlib. Calling stdlib directly on a clean tree cannot load
    %% elixir_compiler because lib/elixir/ebin does not exist yet.
    ok = run(
        absolute_build_path(maps:get(make, Config), ExecutionRoot),
        [MakeShell, OtpBindir, GenerateApp, "-j" ++ Jobs, "erlang"] ++ maps:get(make_options, Config),
        Source,
        BuildEnvironment
    ),
    ok = run(
        absolute_build_path(maps:get(make, Config), ExecutionRoot),
        [MakeShell, OtpBindir, GenerateApp, "-j" ++ Jobs, "stdlib"] ++ maps:get(make_options, Config),
        Source,
        BuildEnvironment
    ),
    ok = artifact_normalizer:normalize_beams(
        filename:join([Source, "lib", "elixir", "ebin"]),
        Work,
        StableSource
    ),
    ok = run(
        absolute_build_path(maps:get(make, Config), ExecutionRoot),
        [MakeShell, OtpBindir, GenerateApp, "-j" ++ Jobs] ++ maps:get(make_options, Config),
        Source,
        BuildEnvironment
    ),
    ok = artifact_normalizer:normalize_beams(filename:join(Source, "lib"), Work, StableSource),
    ok = stage_runtime(Source, Output),
    ok = artifact_normalizer:assert_absent(Output, [Work, absolute(".")]),
    true = filelib:is_file(filename:join([Output, "lib", "elixir", "ebin", "Elixir.Kernel.beam"])),
    true = filelib:is_file(filename:join([Output, "lib", "mix", "ebin", "Elixir.Mix.beam"])),
    ok = verify_runtime(Output, Version, maps:get(otp_release, Config)),
    ok = remove(Work),
    ok.

bind_upstream_scripts_to_declared_shell(Source) ->
    %% Elixir's checked-in launchers use /bin/sh. The action must not borrow
    %% that host path, and a Bazel executable path can exceed the kernel's
    %% shebang limit. Removing the shebang from the writable source copy makes
    %% the declared recipe shell handle direct launcher calls after ENOEXEC.
    Elixir = filename:join(Source, "bin/elixir"),
    {ok, <<"#!/bin/sh\n", ElixirBody/binary>>} = file:read_file(Elixir),
    ok = file:write_file(Elixir, ElixirBody),
    %% elixirc tail-calls bin/elixir with the shell's exec builtin, where an
    %% ENOEXEC fallback is not portable. Bind that one upstream transition to
    %% the already-declared SHELL rather than introducing a host /bin/sh read.
    Elixirc = filename:join(Source, "bin/elixirc"),
    {ok, <<"#!/bin/sh\n", ElixircBody0/binary>>} = file:read_file(Elixirc),
    UpstreamExec = <<"exec \"$SCRIPT_PATH\"/elixir +elixirc \"$@\"">>,
    DeclaredExec = <<"exec \"$SHELL\" \"$SCRIPT_PATH\"/elixir +elixirc \"$@\"">>,
    [_, _] = binary:split(ElixircBody0, UpstreamExec),
    ElixircBody = binary:replace(ElixircBody0, UpstreamExec, DeclaredExec),
    ok = file:write_file(Elixirc, ElixircBody),
    %% BusyBox ash is allowed to reject ENOEXEC fallback entirely. Make the
    %% upstream compile recipes explicit about the declared shell as well. The
    %% replacements only adapt launcher transitions; Elixir/Erlang sources and
    %% compiler arguments stay unchanged.
    Makefile = filename:join(Source, "Makefile"),
    {ok, MakefileBody0} = file:read_file(Makefile),
    MakefileBody = lists:foldl(
        fun({From, To}, Body) -> replace_required(Body, From, To) end,
        MakefileBody0,
        [
            {<<"../../$$(ELIXIRC)">>, <<"$$(SHELL) ../../$$(ELIXIRC)">>},
            {<<"../../$(ELIXIRC_MIN_SIG)">>, <<"$(SHELL) ../../$(ELIXIRC_MIN_SIG)">>},
            {<<"$(Q) $(ELIXIRC_MIN_SIG) lib/elixir/unicode/">>, <<"$(Q) $(SHELL) $(ELIXIRC_MIN_SIG) lib/elixir/unicode/">>},
            {<<"$(Q) cd lib/$(1) && ../../bin/elixir -e">>, <<"$(Q) cd lib/$(1) && $$(SHELL) ../../bin/elixir -e">>},
            {<<"$(Q) bin/elixir lib/elixir/scripts/infer.exs;">>, <<"$(Q) $(SHELL) bin/elixir lib/elixir/scripts/infer.exs;">>}
        ]
    ),
    ok = file:write_file(Makefile, MakefileBody),
    ok.

replace_required(Body, From, To) ->
    case binary:match(Body, From) of
        nomatch -> erlang:error({unsupported_elixir_makefile, From});
        _ -> binary:replace(Body, From, To, [global])
    end.

absolute(Path) ->
    filename:absname(Path).

absolute_build_path(Path, _ExecutionRoot) when hd(Path) =:= $/ ->
    Path;
absolute_build_path(Path, ExecutionRoot) ->
    filename:absname(filename:join(ExecutionRoot, Path)).

expand_path({path, Path}, ExecutionRoot) ->
    absolute_build_path(Path, ExecutionRoot);
expand_path({path_list, Paths}, ExecutionRoot) ->
    string:join([absolute_build_path(Path, ExecutionRoot) || Path <- Paths], ":");
expand_path(Value, _ExecutionRoot) ->
    Value.

expand_runtime_value(Value, ExecutionRoot) ->
    lists:flatten(string:replace(Value, "/proc/self/cwd/", ExecutionRoot ++ "/", all)).

inherit_declared_environment(Environment, Keys) ->
    lists:foldl(
        fun(Key, Accumulator) ->
            case os:getenv(Key) of
                false -> maps:remove(Key, Accumulator);
                Value -> Accumulator#{Key => Value}
            end
        end,
        Environment,
        Keys
    ).

stage_runtime(Source, Output) ->
    ok = ensure_directory(Output),
    lists:foreach(
        fun(App) ->
            ok = copy_entry(
                filename:join([Source, "lib", App, "ebin"]),
                filename:join([Output, "lib", App, "ebin"])
            )
        end,
        ["eex", "elixir", "ex_unit", "iex", "logger", "mix"]
    ),
    VersionPath = filename:join(Source, "VERSION"),
    copy_entry(VersionPath, filename:join(Output, "VERSION")),
    {ok, Version} = file:read_file(VersionPath),
    Marker = filename:join([Output, "bin", ".runtime_root"]),
    ok = ensure_parent(Marker),
    file:write_file(Marker, Version).

verify_runtime(Output, Version, OtpRelease) ->
    OtpRelease = erlang:system_info(otp_release),
    ok = code:add_paths(filelib:wildcard(filename:join([Output, "lib", "*", "ebin"]))),
    VersionBinary = list_to_binary(Version),
    VersionBinary = 'Elixir.System':version(),
    ok.

copy_sources(Sources, ExecutionRoot, Destination) ->
    lists:foreach(
        fun({Source, Relative}) ->
            copy_entry(absolute_build_path(Source, ExecutionRoot), filename:join(Destination, Relative))
        end,
        Sources
    ).

copy_entry(Source0, Destination0) ->
    %% Binary paths preserve source names without depending on a worker's
    %% configured locale.
    Source = unicode:characters_to_binary(Source0),
    Destination = unicode:characters_to_binary(Destination0),
    %% Source files are commonly symlinks into Bazel's repository cache.
    %% Dereference them when entering the writable action tree; preserving
    %% those links would let later build steps mutate action inputs.
    case file:read_file_info(Source) of
        {ok, #file_info{type = directory}} ->
            ok = ensure_directory(Destination),
            {ok, Children} = file:list_dir(Source),
            lists:foreach(
                fun(Child) ->
                    copy_entry(filename:join(Source, Child), filename:join(Destination, Child))
                end,
                Children
            );
        {ok, Info} ->
            ok = ensure_parent(Destination),
            {ok, _Bytes} = file:copy(Source, Destination),
            {ok, CopiedInfo} = file:read_file_info(Destination),
            ok = file:write_file_info(Destination, CopiedInfo#file_info{mode = Info#file_info.mode});
        Error ->
            erlang:error({source_copy_failed, Source, Destination, Error})
    end.

run(Executable0, Arguments, WorkingDirectory, Environment) ->
    Executable = absolute(Executable0),
    Port = open_port(
        {spawn_executable, Executable},
        [
            binary,
            exit_status,
            stderr_to_stdout,
            use_stdio,
            {args, Arguments},
            {cd, WorkingDirectory},
            {env, maps:to_list(Environment)}
        ]
    ),
    await(Port, Executable).

await(Port, Executable) ->
    receive
        {Port, {data, Data}} ->
            ok = io:put_chars(Data),
            await(Port, Executable);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Status}} ->
            erlang:error({command_failed, Executable, Status})
    end.

ensure_directory(Path) ->
    filelib:ensure_dir(filename:join(Path, ".keep")).

ensure_parent(Path) ->
    filelib:ensure_dir(Path).

remove(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> file:del_dir_r(Path);
        {ok, _Info} -> file:delete(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.
