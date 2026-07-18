%% Shell-free action driver for Elixir's upstream Makefile build.
-module(elixir_build_driver).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([ConfigPath]) ->
    {ok, [Config]} = file:consult(ConfigPath),
    Output = absolute(maps:get(output, Config)),
    Work = Output ++ ".work",
    Source = filename:join(Work, "source"),
    Tools = filename:join(Work, "tools"),
    ok = remove(Work),
    ok = remove(Output),
    ok = ensure_directory(Source),
    ok = ensure_directory(Tools),
    copy_sources(maps:get(sources, Config), Source),
    ok = bind_upstream_scripts_to_declared_shell(Source),
    Version = maps:get(version, Config),
    {ok, SourceVersion0} = file:read_file(filename:join(Source, "VERSION")),
    Version = string:trim(binary_to_list(SourceVersion0)),
    Erl = absolute(maps:get(erlexec, Config)),
    ok = file:make_symlink(Erl, filename:join(Tools, "erl")),
    Environment0 = maps:get(environment, Config),
    Environment1 = maps:map(fun(_Key, Value) -> expand_path(Value) end, Environment0),
    Environment = inherit_crypto_environment(Environment1),
    BuildEnvironment = Environment#{
        "ERL_COMPILER_OPTIONS" => "deterministic",
        "ERL_AFLAGS" => maps:get(erl_aflags, Config),
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
    GenerateApp = "GENERATE_APP=" ++ absolute(maps:get(escript, Config)) ++ " " ++
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
        maps:get(make, Config),
        [MakeShell, OtpBindir, GenerateApp, "-j" ++ Jobs, "erlang"] ++ maps:get(make_options, Config),
        Source,
        BuildEnvironment
    ),
    ok = run(
        maps:get(make, Config),
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
        maps:get(make, Config),
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
    %% shebang limit. Removing only the shebang from the writable source copy
    %% makes the declared Bash executing each Make recipe handle the unchanged
    %% upstream script body after execve returns ENOEXEC.
    lists:foreach(
        fun(Relative) ->
            Path = filename:join(Source, Relative),
            {ok, <<"#!/bin/sh\n", Body/binary>>} = file:read_file(Path),
            ok = file:write_file(Path, Body)
        end,
        ["bin/elixir", "bin/elixirc"]
    ),
    ok.

absolute(Path) ->
    filename:absname(Path).

expand_path({path, Path}) ->
    absolute(Path);
expand_path({path_list, Paths}) ->
    string:join([absolute(Path) || Path <- Paths], ":");
expand_path(Value) ->
    Value.

inherit_crypto_environment(Environment) ->
    lists:foldl(
        fun(Key, Accumulator) ->
            case os:getenv(Key) of
                false -> maps:remove(Key, Accumulator);
                Value -> Accumulator#{Key => Value}
            end
        end,
        Environment,
        ["OPENSSL_CONF", "OPENSSL_MODULES", "FIPS_MODULE_CONF"]
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
    copy_entry(filename:join(Source, "VERSION"), filename:join(Output, "VERSION")).

verify_runtime(Output, Version, OtpRelease) ->
    OtpRelease = erlang:system_info(otp_release),
    ok = code:add_paths(filelib:wildcard(filename:join([Output, "lib", "*", "ebin"]))),
    VersionBinary = list_to_binary(Version),
    VersionBinary = 'Elixir.System':version(),
    ok.

copy_sources(Sources, Destination) ->
    lists:foreach(
        fun({Source, Relative}) -> copy_entry(absolute(Source), filename:join(Destination, Relative)) end,
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
