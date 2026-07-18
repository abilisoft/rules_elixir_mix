%% Boot a Mix release through its packaged native erlexec, without its shell launcher.
-module(release_runtime_test).
-export([main/1]).

main([ReleaseRoot0, ReleaseName, AppName, CryptoActivation0, CryptoEnvironmentCount0 | Rest]) ->
    ReleaseRoot = filename:absname(ReleaseRoot0),
    CryptoActivation = list_to_existing_atom(CryptoActivation0),
    CryptoEnvironmentCount = list_to_integer(CryptoEnvironmentCount0),
    {CryptoEnvironmentKeys, RequiredPaths} = lists:split(CryptoEnvironmentCount, Rest),
    TestRoot = filename:absname(os:getenv("TEST_TMPDIR", ".")),
    RuntimeState = filename:join(TestRoot, "release-runtime"),
    ok = ensure_directory(RuntimeState),
    {ok, StartData} = file:read_file(filename:join([ReleaseRoot, "releases", "start_erl.data"])),
    [ErtsVersion, ReleaseVersion | _] = string:tokens(binary_to_list(StartData), " \t\r\n"),
    ErtsBin = filename:join([ReleaseRoot, "erts-" ++ ErtsVersion, "bin"]),
    ErlExec = filename:join(ErtsBin, "erlexec"),
    true = filelib:is_regular(ErlExec),
    StartBoot = filename:join([ReleaseRoot, "releases", ReleaseVersion, "start"]),
    SysConfig = filename:join([ReleaseRoot, "releases", ReleaseVersion, "sys"]),
    true = filelib:is_regular(StartBoot ++ ".boot"),
    true = filelib:is_regular(SysConfig ++ ".config"),
    lists:foreach(
        fun(Relative) ->
            Path = filename:join(ReleaseRoot, Relative),
            true = filelib:is_regular(Path) orelse filelib:is_dir(Path)
        end,
        RequiredPaths
    ),
    App = list_to_atom(AppName),
    Evaluation = lists:flatten(io_lib:format(
        "{ok,_}=application:ensure_all_started(~tp),"
        "io:format(\"release-runtime-ok ~~tp~n\",[~tp]),halt().",
        [App, App]
    )),
    Arguments = [
        "-boot", StartBoot,
        "-boot_var", "RELEASE_LIB", filename:join(ReleaseRoot, "lib"),
        "-mode", "embedded",
        "-config", SysConfig,
        "-noshell",
        "-eval", Evaluation
    ],
    CryptoEnvironment = case CryptoActivation of
        true -> [{"RULES_ELIXIR_MIX_CRYPTO_STATE", filename:join(RuntimeState, "crypto")}];
        false -> [{"RULES_ELIXIR_MIX_CRYPTO_STATE", false}]
    end,
    AmbientCryptoEnvironment = [
        {Key, false}
        || Key <- lists:usort([
            "FIPS_MODULE_CONF",
            "OPENSSL_CONF",
            "OPENSSL_MODULES",
            "RULES_ELIXIR_MIX_CRYPTO_STATE"
            | CryptoEnvironmentKeys
        ])
    ],
    Environment = AmbientCryptoEnvironment ++ CryptoEnvironment ++ [
        {"BINDIR", ErtsBin},
        {"EMU", "beam"},
        {"ERL_AFLAGS", false},
        {"ERL_FLAGS", false},
        {"ERL_LIBS", false},
        {"HOME", filename:join(RuntimeState, "home")},
        {"LANG", "C"},
        {"LC_ALL", "C"},
        {"LD_LIBRARY_PATH", false},
        {"PATH", ErtsBin},
        {"PROGNAME", ReleaseName},
        {"RELEASE_MODE", "embedded"},
        {"RELEASE_NAME", ReleaseName},
        {"RELEASE_ROOT", ReleaseRoot},
        {"RELEASE_VSN", ReleaseVersion},
        {"ROOTDIR", ReleaseRoot},
        {"TZ", "UTC"}
    ],
    Output = run(ErlExec, Arguments, Environment, ReleaseRoot),
    case binary:match(Output, <<"release-runtime-ok">>) of
        nomatch -> erlang:error({release_did_not_confirm_startup, Output});
        _ -> io:put_chars(Output)
    end,
    ok.

ensure_directory(Path) ->
    filelib:ensure_path(filename:join(Path, "placeholder")),
    case file:make_dir(Path) of
        ok -> ok;
        {error, eexist} -> ok
    end.

run(Executable, Arguments, Environment, Directory) ->
    Port = open_port(
        {spawn_executable, Executable},
        [
            binary,
            exit_status,
            stderr_to_stdout,
            use_stdio,
            {args, Arguments},
            {cd, Directory},
            {env, Environment}
        ]
    ),
    await(Port, []).

await(Port, Chunks) ->
    receive
        {Port, {data, Data}} -> await(Port, [Data | Chunks]);
        {Port, {exit_status, 0}} -> iolist_to_binary(lists:reverse(Chunks));
        {Port, {exit_status, Status}} ->
            erlang:error({release_runtime_failed, Status, iolist_to_binary(lists:reverse(Chunks))})
    end.
