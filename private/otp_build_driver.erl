%% Shell-free action driver for OTP's upstream configure/make build.
-module(otp_build_driver).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([ConfigPath]) ->
    {ok, [Config]} = file:consult(ConfigPath),
    Output = absolute(maps:get(output, Config)),
    ErlOutput = absolute(maps:get(erl_output, Config)),
    ErtsBinOutput = absolute(maps:get(erts_bin_output, Config)),
    Work = Output ++ ".work",
    Source = filename:join(Work, "source"),
    ok = remove(Work),
    ok = remove(Output),
    ok = remove(ErtsBinOutput),
    ok = ensure_directory(Source),
    copy_sources(maps:get(sources, Config), Source),
    ok = restore_source_directories(absolute(maps:get(source_directories, Config)), Source),
    ok = normalize_interpreters(
        Source,
        absolute(maps:get(bash, Config)),
        absolute(maps:get(perl, Config)),
        absolute(maps:get(escript, Config))
    ),
    ExecutionRoot = absolute("."),
    Environment0 = maps:get(environment, Config),
    Environment1 = maps:map(fun(_Key, Value) -> expand_path(Value) end, Environment0),
    Environment2 = compiler_flag_environment(Config, Environment1, ExecutionRoot),
    Environment = crypto_link_environment(Config, Environment2, ExecutionRoot),
    PrefixMap = " " ++ shell_join([
        "-ffile-prefix-map=" ++ Work ++ "=.",
        "-fdebug-prefix-map=" ++ Work ++ "=."
    ]),
    BuildEnvironment = Environment#{
        "BINDIR" => false,
        "CFLAGS" => maps:get("CFLAGS", Environment, "") ++ PrefixMap,
        "CXXFLAGS" => maps:get("CXXFLAGS", Environment, "") ++ PrefixMap,
        "EMU" => false,
        "ERL_AFLAGS" => false,
        "ERL_COMPILER_OPTIONS" => false,
        "ERL_FLAGS" => false,
        "ERL_LIBS" => false,
        "ERL_ROOTDIR" => false,
        "ERL_ZFLAGS" => false,
        "HOME" => filename:join(Work, "home"),
        "LANG" => "C",
        "LC_ALL" => "C",
        "SOURCE_DATE_EPOCH" => "946684800",
        "PROGNAME" => false,
        "ROOTDIR" => false,
        "RULES_ELIXIR_MIX_ERTS_PATH" => false,
        "TMPDIR" => filename:join(Work, "tmp"),
        "TZ" => "UTC"
    },
    ok = ensure_directory(maps:get("HOME", BuildEnvironment)),
    ok = ensure_directory(maps:get("TMPDIR", BuildEnvironment)),
    BootstrapErlExec = absolute(maps:get(bootstrap_erlexec, Config)),
    BootstrapErtsBin = absolute(maps:get(bootstrap_erts_bin, Config)),
    FipsRequired = maps:get(fips_required, Config, false),
    StaticCryptoNif = maps:get(static_crypto_nif, Config, false),
    CryptoOptions = crypto_options(maps:get(crypto_sdk, Config, none), FipsRequired, StaticCryptoNif),
    ConfigureOptions = ["--prefix=/"] ++ CryptoOptions ++ maps:get(configure_options, Config),
    ok = run(
        maps:get(bash, Config),
        [filename:join(Source, "configure")] ++ ConfigureOptions,
        Source,
        BuildEnvironment
    ),
    ok = artifact_normalizer:scrub_erts_commandline_flags(Source),
    ok = artifact_normalizer:scrub_erts_build_metadata(Source),
    MakeEnvironment0 = with_otp_bootstrap_path(Source, BuildEnvironment),
    MakeEnvironment = MakeEnvironment0#{
        "ERLC_EMULATOR" => filename:join([Source, "bootstrap", "bin", "erl"])
    },
    %% Bootstrap through the declared native erlexec. A valid bootstrap
    %% runtime need not package OTP's bin/erl shell launcher, and a source-built
    %% output from this rule can therefore bootstrap the next OTP release.
    ExternalBootstrapEnvironment = MakeEnvironment0#{
        "BINDIR" => BootstrapErtsBin,
        "EMU" => "beam",
        "ERL_ROOTDIR" => absolute(maps:get(bootstrap_root, Config)),
        "ERLC_EMULATOR" => BootstrapErlExec,
        "PROGNAME" => "erl",
        "ROOTDIR" => absolute(maps:get(bootstrap_root, Config)),
        "RULES_ELIXIR_MIX_ERTS_PATH" => BootstrapErtsBin
    },
    Jobs = integer_to_list(maps:get(jobs, Config)),
    MakeShell = "SHELL=" ++ maps:get("SHELL", MakeEnvironment),
    MakeDeterministic = "ERL_DETERMINISTIC=yes",
    %% OTP's generated Makefiles assign ARFLAGS themselves, so the action's
    %% environment alone cannot carry the C/C++ toolchain's deterministic
    %% archive policy. A command-line assignment has Make's required priority.
    MakeArFlags = "ARFLAGS=" ++ maps:get("ARFLAGS", MakeEnvironment),
    MakeVariables = [MakeShell, MakeDeterministic, MakeArFlags],
    MakeOptions = maps:get(make_options, Config),
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ ["-j" ++ Jobs] ++ MakeOptions ++ ["erl_interface"],
        Source,
        ExternalBootstrapEnvironment
    ),
    PgoMakeOptions = case otp_pgo_enabled(Source) of
        true ->
            %% OTP's PGO graph replaces the emulator used by bootstrap/bin/erl.
            %% Build the profiling VM first, then let all_bootstraps build the
            %% profile-use VM without traversing the phony profile prerequisites
            %% a second time.
            ok = run(
                maps:get(make, Config),
                MakeVariables ++ ["-j" ++ Jobs] ++ MakeOptions ++ ["emulator_profile_generate"],
                Source,
                ExternalBootstrapEnvironment
            ),
            ["PROFILE_EMU_DEPS=", "PROFILE=use"];
        false ->
            []
    end,
    %% Finish the profile-use (or ordinary) emulator while compilation still
    %% uses the declared bootstrap runtime. Replacing beam.smp while invoking it
    %% through source/bootstrap/bin/erl is not safe.
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ ["-j" ++ Jobs] ++ PgoMakeOptions ++ MakeOptions ++ ["emulator"],
        Source,
        ExternalBootstrapEnvironment
    ),
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ ["-j" ++ Jobs] ++ MakeOptions ++ ["bootstrap_setup"],
        Source,
        ExternalBootstrapEnvironment
    ),
    %% OTP documents all_bootstraps as the complete compiler bootstrap
    %% boundary. The final emulator and primary launcher now exist, so its
    %% secondary and tertiary applications can use the source runtime safely.
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ ["-j" ++ Jobs] ++ PgoMakeOptions ++ MakeOptions ++ ["all_bootstraps"],
        Source,
        MakeEnvironment
    ),
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ ["-j" ++ Jobs] ++ PgoMakeOptions ++ MakeOptions,
        Source,
        MakeEnvironment
    ),
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ PgoMakeOptions ++ MakeOptions ++ ["install", "DESTDIR=" ++ Output],
        Source,
        MakeEnvironment
    ),
    RuntimeRoot = filename:join([Output, "lib", "erlang"]),
    StableSource = "/rules_elixir_mix/sources/otp-" ++ maps:get(version, Config),
    ok = artifact_normalizer:prune_script_launchers(RuntimeRoot),
    %% OTP's DESTDIR install also creates top-level bin symlinks to the shell
    %% launchers under lib/erlang/bin. Those launchers are intentionally pruned;
    %% consumers invoke the separately declared native erlexec artifact.
    ok = remove(filename:join(Output, "bin")),
    ok = artifact_normalizer:normalize_tree(RuntimeRoot, Work, StableSource),
    ok = artifact_normalizer:assert_absent(RuntimeRoot, [Work, ExecutionRoot]),
    {ok, StartErlData} = file:read_file(filename:join([RuntimeRoot, "releases", "start_erl.data"])),
    [ErtsVersion, OtpRelease | _] = string:tokens(binary_to_list(StartErlData), " \t\r\n"),
    {ok, InstalledOtpVersion0} = file:read_file(
        filename:join([RuntimeRoot, "releases", OtpRelease, "OTP_VERSION"])
    ),
    ExpectedOtpVersion = maps:get(version, Config),
    ExpectedOtpVersion = string:trim(binary_to_list(InstalledOtpVersion0)),
    InstalledErtsBin = filename:join([RuntimeRoot, "erts-" ++ ErtsVersion, "bin"]),
    InstalledErlExec = filename:join(InstalledErtsBin, "erlexec"),
    true = filelib:is_file(InstalledErlExec),
    ok = link_erts_bin(InstalledErtsBin, ErtsBinOutput, Output),
    VerificationEnvironment0 = activate_crypto(Config, Work, MakeEnvironment),
    VerificationEnvironment = runtime_environment(RuntimeRoot, ErtsBinOutput, VerificationEnvironment0),
    ok = verify_crypto(
        FipsRequired,
        StaticCryptoNif,
        filename:join(ErtsBinOutput, "erlexec"),
        Work,
        VerificationEnvironment
    ),
    ok = ensure_parent(ErlOutput),
    ok = remove(ErlOutput),
    RelativeErl = filename:join([filename:basename(ErtsBinOutput), "erlexec"]),
    ok = file:make_symlink(RelativeErl, ErlOutput),
    ok = remove(Work),
    ok.

with_otp_bootstrap_path(Source, Environment) ->
    Target = otp_target(Source),
    BootstrapBin = filename:join([Source, "bin", Target]),
    PrimaryBootstrapBin = filename:join([Source, "bootstrap", "bin"]),
    Existing = maps:get("PATH", Environment, ""),
    Environment#{
        "PATH" => string:join([BootstrapBin, PrimaryBootstrapBin, Existing], ":")
    }.

otp_target(Source) ->
    GeneratedMakefiles = lists:sort([
        Path
        || Path <- filelib:wildcard(filename:join([Source, "erts", "emulator", "*", "Makefile"])),
           filename:basename(filename:dirname(Path)) =/= "test"
    ]),
    case GeneratedMakefiles of
        [Makefile] ->
            filename:basename(filename:dirname(Makefile));
        _ -> erlang:error({ambiguous_otp_bootstrap_target, GeneratedMakefiles})
    end.

otp_pgo_enabled(Source) ->
    OtpMakefile = filename:join([Source, "make", otp_target(Source), "otp.mk"]),
    {ok, Contents} = file:read_file(OtpMakefile),
    re:run(Contents, <<"(?m)^USE_PGO[[:space:]]*=[[:space:]]*true[[:space:]]*$">>) =/= nomatch.

absolute(Path) ->
    filename:absname(Path).

expand_path({path, Path}) ->
    absolute(Path);
expand_path({path_list, Paths}) ->
    string:join([absolute(Path) || Path <- Paths], ":");
expand_path(Value) ->
    Value.

compiler_flag_environment(Config, Environment, ExecutionRoot) ->
    DynamicFlags = shell_join(normalize_flags(maps:get(ded_ldflags, Config, []), ExecutionRoot)),
    DynamicLibraries = shell_join(normalize_flags(maps:get(ded_libs, Config, []), ExecutionRoot)),
    Environment#{
        "ARFLAGS" => shell_join(normalize_flags(maps:get(arflags, Config, []), ExecutionRoot)),
        "CFLAGS" => shell_join(normalize_flags(maps:get(cflags, Config, []), ExecutionRoot)),
        "CXXFLAGS" => shell_join(normalize_flags(maps:get(cxxflags, Config, []), ExecutionRoot)),
        "DED_LD" => absolute(maps:get(ded_ld, Config)),
        "DED_LD_FLAG_RUNTIME_LIBRARY_PATH" => maps:get(ded_ld_runtime_library_path, Config),
        "DED_LIBS" => DynamicLibraries,
        "DED_LDFLAGS" => DynamicFlags,
        "DED_LDFLAGS_CONFTEST" => DynamicFlags,
        "LDFLAGS" => shell_join(normalize_flags(maps:get(ldflags, Config, []), ExecutionRoot))
    }.

shell_join(Values) ->
    string:join([shell_quote(Value) || Value <- Values], " ").

shell_quote([]) ->
    "''";
shell_quote(Value) ->
    Safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-",
    case lists:all(fun(Character) -> lists:member(Character, Safe) end, Value) of
        true -> Value;
        false -> "'" ++ lists:flatten(string:replace(Value, "'", "'\"'\"'", all)) ++ "'"
    end.

crypto_link_environment(Config, Environment, ExecutionRoot) ->
    ToolchainLibraries = normalize_flags(maps:get(libraries, Config, []), ExecutionRoot),
    case maps:get(crypto_sdk, Config, none) of
        none ->
            Environment#{"LIBS" => shell_join(ToolchainLibraries)};
        Sysroot0 ->
            Archive = filename:join([absolute(Sysroot0), "lib", "libcrypto.a"]),
            LinkOptions = normalize_flags(maps:get(crypto_linkopts, Config, []), ExecutionRoot),
            Environment#{"LIBS" => shell_join([Archive | LinkOptions] ++ ToolchainLibraries)}
    end.

normalize_flags([], _ExecutionRoot) ->
    [];
normalize_flags([Flag, Path | Rest], ExecutionRoot)
        when Flag =:= "-I"; Flag =:= "-L"; Flag =:= "-B"; Flag =:= "-isystem"; Flag =:= "--sysroot" ->
    [Flag, absolute_build_path(Path, ExecutionRoot) | normalize_flags(Rest, ExecutionRoot)];
normalize_flags([Flag | Rest], ExecutionRoot) ->
    [normalize_flag(Flag, ExecutionRoot) | normalize_flags(Rest, ExecutionRoot)].

normalize_flag(Flag, ExecutionRoot) ->
    Prefixes = ["--sysroot=", "-isystem", "-I", "-L", "-B"],
    normalize_prefixed_flag(Flag, Prefixes, ExecutionRoot).

normalize_prefixed_flag(Flag, [], _ExecutionRoot) ->
    Flag;
normalize_prefixed_flag(Flag, [Prefix | Rest], ExecutionRoot) ->
    case lists:prefix(Prefix, Flag) andalso length(Flag) > length(Prefix) of
        true ->
            Path = lists:nthtail(length(Prefix), Flag),
            Prefix ++ absolute_build_path(Path, ExecutionRoot);
        false ->
            normalize_prefixed_flag(Flag, Rest, ExecutionRoot)
    end.

absolute_build_path(Path, ExecutionRoot) ->
    case filename:pathtype(Path) of
        absolute -> Path;
        _ -> filename:join(ExecutionRoot, Path)
    end.

normalize_interpreters(Path, Bash, Perl, Escript) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Children} = file:list_dir(Path),
            lists:foreach(
                fun(Child) ->
                    ok = normalize_interpreters(filename:join(Path, Child), Bash, Perl, Escript)
                end,
                Children
            ),
            ok;
        %% OTP generates executable launchers from non-executable *.src templates.
        %% Normalize the templates too so every launcher used by configure/make
        %% retains the declared Bazel interpreter instead of /bin/sh.
        {ok, #file_info{type = regular}} ->
            normalize_interpreter(Path, Bash, Perl, Escript);
        {ok, _Info} ->
            ok;
        Error ->
            Error
    end.

normalize_interpreter(Path, Bash, Perl, Escript) ->
    {ok, File} = file:open(Path, [read, binary]),
    FirstLine = file:read_line(File),
    ok = file:close(File),
    case FirstLine of
        {ok, Line} ->
            case interpreter(Line, Bash, Perl, Escript) of
                none -> ok;
                Replacement -> replace_shebang(Path, Replacement)
            end;
        eof -> ok;
        Error -> Error
    end.

interpreter(Line, Bash, Perl, Escript) ->
    Trimmed = string:trim(binary_to_list(Line)),
    case lists:prefix("#!", Trimmed) of
        false -> none;
        true ->
            Tokens = string:tokens(string:trim(lists:nthtail(2, Trimmed)), " \t"),
            case Tokens of
                ["/usr/bin/env", Command | Arguments] ->
                    declared_interpreter(Command, Arguments, Bash, Perl, Escript);
                [Command | Arguments] ->
                    declared_interpreter(Command, Arguments, Bash, Perl, Escript);
                [] ->
                    none
            end
    end.

declared_interpreter(Command, Arguments, Bash, Perl, Escript) ->
    case filename:basename(Command) of
        "bash" -> {Bash, Arguments};
        "sh" -> {Bash, Arguments};
        "perl" -> {Perl, Arguments};
        "escript" -> {Escript, Arguments};
        _ -> none
    end.

replace_shebang(Path, {Interpreter, Arguments}) ->
    {ok, Content} = file:read_file(Path),
    ArgumentSuffix = case Arguments of
        [] -> "";
        _ -> " " ++ string:join(Arguments, " ")
    end,
    case binary:split(Content, <<"\n">>) of
        [_First, Rest] ->
            file:write_file(Path, ["#!", Interpreter, ArgumentSuffix, "\n", Rest]);
        _ -> erlang:error({invalid_launcher, Path})
    end.

crypto_options(none, false, false) ->
    ["--without-ssl"];
crypto_options(none, FipsRequired, StaticCryptoNif) ->
    erlang:error({crypto_sdk_required, FipsRequired, StaticCryptoNif});
crypto_options(Path0, FipsRequired, StaticCryptoNif) ->
    Path = absolute(Path0),
    true = filelib:is_dir(filename:join(Path, "include")),
    true = filelib:is_file(filename:join([Path, "lib", "libcrypto.a"])),
    ["--with-ssl=" ++ Path, "--disable-dynamic-ssl-lib"] ++
        option(FipsRequired, "--enable-fips") ++
        option(StaticCryptoNif, "--enable-static-nifs").

option(true, Value) -> [Value];
option(false, _Value) -> [].

activate_crypto(Config, Work, Environment) ->
    case maps:get(crypto_activation_tool, Config, none) of
        none ->
            IsolationRoot = filename:join(Work, "crypto_isolation"),
            ok = ensure_directory(IsolationRoot),
            IsolationConfig = filename:join(IsolationRoot, "openssl.cnf"),
            ok = file:write_file(IsolationConfig, <<>>),
            maps:merge(
                maps:without(["OPENSSL_CONF", "OPENSSL_MODULES", "FIPS_MODULE_CONF"], Environment),
                #{
                    "OPENSSL_CONF" => IsolationConfig,
                    "OPENSSL_MODULES" => IsolationRoot,
                    "FIPS_MODULE_CONF" => IsolationConfig
                }
            );
        Tool ->
            Sysroot = absolute(maps:get(crypto_sdk, Config)),
            ActivationRoot = filename:join(Work, "crypto_activation"),
            ok = ensure_directory(ActivationRoot),
            IsolationRoot = filename:join(ActivationRoot, "isolation"),
            ok = ensure_directory(IsolationRoot),
            IsolationConfig = filename:join(IsolationRoot, "openssl.cnf"),
            ok = file:write_file(IsolationConfig, <<>>),
            SanitizedEnvironment = maps:merge(
                maps:without(["OPENSSL_CONF", "OPENSSL_MODULES", "FIPS_MODULE_CONF"], Environment),
                #{
                    "OPENSSL_CONF" => IsolationConfig,
                    "OPENSSL_MODULES" => IsolationRoot,
                    "FIPS_MODULE_CONF" => IsolationConfig
                }
            ),
            Expand = fun(Value) ->
                replace_template(Value, Sysroot, ActivationRoot)
            end,
            Arguments = [Expand(Value) || Value <- maps:get(crypto_activation_args, Config, [])],
            ok = run(Tool, Arguments, Work, SanitizedEnvironment),
            RuntimeEnvironment = maps:map(
                fun(_Key, Value) -> Expand(Value) end,
                maps:get(crypto_runtime_environment, Config, #{})
            ),
            maps:merge(SanitizedEnvironment, RuntimeEnvironment)
    end.

replace_template(Value, Sysroot, ActivationRoot) ->
    WithSysroot = string:replace(Value, "{sysroot}", Sysroot, all),
    lists:flatten(string:replace(WithSysroot, "{activation_root}", ActivationRoot, all)).

runtime_environment(Root, ErtsBin, Environment) ->
    Environment#{
        "BINDIR" => absolute(ErtsBin),
        "EMU" => "beam",
        "ERL_ROOTDIR" => false,
        "PATH" => absolute(ErtsBin),
        "PROGNAME" => "erl",
        "ROOTDIR" => absolute(Root)
    }.

link_erts_bin(Source, Destination, InstallRoot) ->
    ok = ensure_directory(Destination),
    {ok, Children} = file:list_dir(Source),
    RelativeSource = filename:join([
        "..",
        filename:basename(InstallRoot),
        "lib",
        "erlang",
        filename:basename(filename:dirname(Source)),
        "bin"
    ]),
    lists:foreach(
        fun(Child) ->
            ok = file:make_symlink(
                filename:join(RelativeSource, Child),
                filename:join(Destination, Child)
            )
        end,
        Children
    ).

verify_crypto(false, false, _InstalledErl, _Work, _Environment) ->
    ok;
verify_crypto(FipsRequired, true, InstalledErl, Work, Environment) ->
    FipsExpression = case FipsRequired of
        true ->
            "enabled=crypto:info_fips()," ++
            "32=byte_size(crypto:hash(sha256,<<\"rules_elixir_mix\">>))," ++
            "{'EXIT',_}=catch crypto:hash(md5,<<\"must fail\">>),";
        false ->
            ""
    end,
    Expression =
        "application:load(crypto)," ++
        option_expression(FipsRequired, "ok=application:set_env(crypto,fips_mode,true),") ++
        "{ok,_}=application:ensure_all_started(crypto)," ++
        "#{link_type:=static}=crypto:info()," ++
        FipsExpression ++
        "io:format(\"verified OTP static crypto runtime: ~tp ~tp~n\",[crypto:info(),crypto:info_lib()])," ++
        "halt(0).",
    run(
        InstalledErl,
        ["-noshell"] ++ option(FipsRequired, "-crypto") ++ option(FipsRequired, "fips_mode") ++
            option(FipsRequired, "true") ++ ["-eval", Expression],
        Work,
        Environment
    ).

option_expression(true, Value) -> Value;
option_expression(false, _Value) -> "".

copy_sources(Sources, Destination) ->
    lists:foreach(
        fun({Source, Relative}) -> copy_entry(absolute(Source), filename:join(Destination, Relative)) end,
        Sources
    ).

restore_source_directories(Manifest, Source) ->
    %% Bazel source targets carry files and symlinks, not empty directories.
    %% The checksum-pinned repository rule records the extracted topology so
    %% staging can reproduce the upstream archive exactly without a shell.
    {ok, Contents} = file:read_file(Manifest),
    lists:foreach(
        fun
            (<<>>) -> ok;
            (Relative) ->
                case filename:pathtype(Relative) =:= relative andalso
                    not lists:member(<<"..">>, filename:split(Relative)) of
                    true -> ok = ensure_directory(filename:join(Source, Relative));
                    false -> erlang:error({invalid_source_directory, Relative})
                end
        end,
        binary:split(Contents, <<"\n">>, [global])
    ),
    ok.

copy_entry(Source0, Destination0) ->
    %% Keep raw UTF-8 file names independent of the action's C locale. OTP's
    %% own source tests contain non-ASCII paths; binary file names avoid an
    %% ambient locale conversion while preserving their exact bytes.
    Source = unicode:characters_to_binary(Source0),
    Destination = unicode:characters_to_binary(Destination0),
    %% Bazel commonly exposes declared source inputs as symlinks into its
    %% repository cache. Copy their contents into the writable action tree so
    %% configure and Make can never mutate action inputs.
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
