%% Boot a Mix release through its packaged native erlexec, without its shell launcher.
-module(release_runtime_test).
-export([main/1]).

main([ReleaseRoot0, ReleaseName, AppName, CryptoActivation0, FipsRequired0,
      CryptoEnvironmentCount0, RequiredPathCount0, RequiredContentCount0,
      ProtocolCount0 | Rest]) ->
    ReleaseRoot = filename:absname(ReleaseRoot0),
    CryptoActivation = list_to_existing_atom(CryptoActivation0),
    FipsRequired = list_to_existing_atom(FipsRequired0),
    CryptoEnvironmentCount = list_to_integer(CryptoEnvironmentCount0),
    RequiredPathCount = list_to_integer(RequiredPathCount0),
    RequiredContentCount = list_to_integer(RequiredContentCount0),
    ProtocolCount = list_to_integer(ProtocolCount0),
    {CryptoEnvironmentKeys, Rest1} = lists:split(CryptoEnvironmentCount, Rest),
    {RequiredPaths, Rest2} = lists:split(RequiredPathCount, Rest1),
    {RequiredContentArguments, ProtocolNames} = lists:split(RequiredContentCount * 2, Rest2),
    ProtocolCount = length(ProtocolNames),
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
    lists:foreach(
        fun({Relative, Expected}) ->
            {ok, ExpectedBinary} = file:read_file(filename:join(ReleaseRoot, Relative)),
            ExpectedBinary = iolist_to_binary(Expected)
        end,
        pairs(RequiredContentArguments)
    ),
    App = list_to_atom(AppName),
    Protocols = [list_to_atom(Name) || Name <- ProtocolNames],
    FipsEvaluation = case FipsRequired of
        true ->
            "{ok,_}=application:ensure_all_started(crypto),"
            "enabled=crypto:info_fips(),#{link_type:=static}=crypto:info(),"
            "32=byte_size(crypto:hash(sha256,<<\"rules_elixir_mix\">>)),"
            "case catch crypto:hash(md5,<<\"must fail\">>) of {'EXIT',_}->ok;"
            "Unexpected->erlang:error({prohibited_md5_succeeded,Unexpected}) end,";
        false -> ""
    end,
    Evaluation = lists:flatten(io_lib:format(
        "~s"
        "lists:foreach(fun(P)->true=P:'__protocol__'('consolidated?') end,~tp),"
        "{ok,_}=application:ensure_all_started(~tp),"
        "io:format(\"release-runtime-ok ~~tp~n\",[~tp]),halt().",
        [FipsEvaluation, Protocols, App, App]
    )),
    RuntimeSysConfig = case CryptoActivation of
        true -> "{activation_root}/sys";
        false -> SysConfig
    end,
    Arguments = [
        "+fnu"
    ] ++ fips_arguments(FipsRequired) ++ [
        "-boot", StartBoot,
        "-boot_var", "RELEASE_LIB", filename:join(ReleaseRoot, "lib"),
        "-mode", "embedded",
        "-config", RuntimeSysConfig,
        "-noshell",
        "-eval", Evaluation
    ],
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
    Environment = AmbientCryptoEnvironment ++ [
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
    Output = case CryptoActivation of
        true ->
            run_packaged_release(
                FipsRequired,
                ReleaseRoot,
                ReleaseName,
                ErlExec,
                Arguments,
                Environment,
                RuntimeState
            );
        false ->
            run(ErlExec, Arguments, Environment, ReleaseRoot)
    end,
    case binary:match(Output, <<"release-runtime-ok">>) of
        nomatch -> erlang:error({release_did_not_confirm_startup, Output});
        _ -> io:put_chars(Output)
    end,
    ok.

fips_arguments(true) -> ["-crypto", "fips_mode", "true"];
fips_arguments(false) -> [].

run_packaged_release(
    FipsRequired,
    ReleaseRoot,
    ReleaseName,
    ErlExec,
    RuntimeArguments,
    Environment,
    RuntimeState
) ->
    State = filename:join(RuntimeState, "crypto"),
    ok = ensure_directory(State),
    SdkRoot = filename:join([ReleaseRoot, ".rules_elixir_mix", "crypto_sdk"]),
    ConfigPath = filename:join([ReleaseRoot, ".rules_elixir_mix", "crypto_activation.config"]),
    {ok, [Config]} = file:consult(ConfigPath),
    Expand = fun(Value) ->
        WithSdk = string:replace(Value, "{sysroot}", SdkRoot, all),
        lists:flatten(string:replace(WithSdk, "{activation_root}", State, all))
    end,
    Tool = filename:join(SdkRoot, maps:get(activation_tool, Config)),
    true = filelib:is_regular(Tool),
    [_ | _] = [Expand(Value) || Value <- maps:get(activation_args, Config)],
    [_ | _] = [
        {Key, Expand(Value)} || {Key, Value} <- maps:get(runtime_environment, Config)
    ],
    Launcher = filename:join([ReleaseRoot, "bin", ReleaseName]),
    true = filelib:is_regular(Launcher),
    LaunchConfigPath = Launcher ++ ".rules_fips.json",
    {ok, LaunchJson} = file:read_file(LaunchConfigPath),
    #{<<"schema">> := 1, <<"command">> := <<"start">>, <<"arguments">> := LaunchArguments} =
        LaunchConfig = json:decode(LaunchJson),
    case FipsRequired of
        true ->
            true = contains_sequence(LaunchArguments, [<<"-crypto">>, <<"fips_mode">>, <<"true">>]);
        false ->
            ok
    end,
    NativeRoot = filename:join(State, "native-release"),
    NativeLauncher = filename:join([NativeRoot, "bin", ReleaseName]),
    ok = ensure_directory(filename:dirname(NativeLauncher)),
    {ok, _} = file:copy(Launcher, NativeLauncher),
    ok = file:change_mode(NativeLauncher, 8#755),
    ReleaseRootBinary = unicode:characters_to_binary(ReleaseRoot),
    LaunchEnvironment = maps:map(
        fun(_Key, Value) ->
            binary:replace(Value, <<"{release_root}">>, ReleaseRootBinary, [global])
        end,
        maps:get(<<"environment">>, LaunchConfig)
    ),
    LaunchRuntimeEnvironment = maps:map(
        fun(_Key, Value) ->
            binary:replace(Value, <<"{release_root}">>, ReleaseRootBinary, [global])
        end,
        maps:get(<<"runtime_environment">>, LaunchConfig)
    ),
    LaunchWritableCopies = [
        Copy#{
            <<"source">> => binary:replace(
                maps:get(<<"source">>, Copy),
                <<"{release_root}">>,
                ReleaseRootBinary,
                [global]
            )
        }
        || Copy <- maps:get(<<"writable_copies">>, LaunchConfig)
    ],
    RuntimeProgram = case filelib:is_regular(
        filename:join(filename:dirname(ErlExec), ".real-" ++ filename:basename(ErlExec))
    ) of
        true -> filename:join(filename:dirname(ErlExec), ".real-" ++ filename:basename(ErlExec));
        false -> ErlExec
    end,
    TestLaunchConfig = LaunchConfig#{
        <<"sdk_root">> => unicode:characters_to_binary(SdkRoot),
        <<"program">> => unicode:characters_to_binary(RuntimeProgram),
        <<"arguments">> => [unicode:characters_to_binary(Value) || Value <- RuntimeArguments],
        <<"environment">> => LaunchEnvironment,
        <<"runtime_environment">> => LaunchRuntimeEnvironment,
        <<"writable_copies">> => LaunchWritableCopies
    },
    ok = file:write_file(
        NativeLauncher ++ ".rules_fips.json",
        json:encode(TestLaunchConfig)
    ),
    run(
        NativeLauncher,
        ["start"],
        lists:keydelete("RULES_ELIXIR_MIX_CRYPTO_STATE", 1, Environment) ++
            [{"RULES_ELIXIR_MIX_CRYPTO_STATE", State}],
        ReleaseRoot
    ).

contains_sequence(Values, Sequence) ->
    contains_sequence(Values, Sequence, length(Sequence)).

contains_sequence(Values, Sequence, Length) when length(Values) >= Length ->
    case lists:sublist(Values, Length) of
        Sequence -> true;
        _ -> contains_sequence(tl(Values), Sequence, Length)
    end;
contains_sequence(_Values, _Sequence, _Length) ->
    false.

pairs([]) ->
    [];
pairs([Key, Value | Rest]) ->
    [{Key, Value} | pairs(Rest)].

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
            Output = iolist_to_binary(lists:reverse(Chunks)),
            io:put_chars(standard_error, Output),
            erlang:error({release_runtime_failed, Status})
    end.
