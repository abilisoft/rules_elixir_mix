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
    Arguments = [
        "+fnu",
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
