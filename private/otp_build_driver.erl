%% Shell-free action driver for OTP's upstream configure/make build.
-module(otp_build_driver).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([ConfigPath]) ->
    {ok, [Config]} = file:consult(ConfigPath),
    Output = absolute(maps:get(output, Config)),
    ErlOutput = absolute(maps:get(erl_output, Config)),
    ErtsBinOutput = absolute(maps:get(erts_bin_output, Config)),
    ExecErtsBinOutput = absolute(maps:get(exec_erts_bin_output, Config)),
    Work = Output ++ ".work",
    Source = filename:join(Work, "source"),
    ok = remove(Work),
    ok = remove(Output),
    ok = remove(ErtsBinOutput),
    ok = remove(ExecErtsBinOutput),
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
    Environment1 = maps:map(fun(_Key, Value) -> expand_path(Value, ExecutionRoot) end, Environment0),
    Environment2 = compiler_flag_environment(Config, Environment1, ExecutionRoot),
    Environment3 = cross_compile_environment(Config, Environment2, ExecutionRoot),
    Environment = crypto_link_environment(Config, Environment3, ExecutionRoot),
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
        "ERL_TOP" => Source,
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
    BootstrapRuntimeEnvironment = maps:map(
        fun(_Key, Value) -> expand_runtime_value(Value, ExecutionRoot) end,
        maps:get(bootstrap_environment, Config)
    ),
    FipsRequired = maps:get(fips_required, Config, false),
    StaticCryptoNif = maps:get(static_crypto_nif, Config, false),
    CrossCompiling = maps:get(cross_compiling, Config, false),
    ok = verify_bootstrap_release(CrossCompiling, maps:get(version, Config)),
    CryptoOptions = crypto_options(maps:get(crypto_sdk, Config, none), FipsRequired, StaticCryptoNif),
    ConfigureOptions = ["--prefix=/"] ++ CryptoOptions ++ maps:get(configure_options, Config),
    try run(
        maps:get(bash, Config),
        [filename:join(Source, "configure")] ++ ConfigureOptions,
        Source,
        BuildEnvironment
    ) of
        ok -> ok
    catch
        Class:Reason:Stacktrace ->
            ok = print_log_tail(filename:join([Source, "erts", "config.log"]), 1000),
            erlang:raise(Class, Reason, Stacktrace)
    end,
    ok = artifact_normalizer:scrub_erts_commandline_flags(Source),
    ok = artifact_normalizer:scrub_erts_build_metadata(Source),
    BootstrapLauncher = absolute(maps:get(bootstrap_launcher, Config)),
    BootstrapTools = stage_bootstrap_tools(BootstrapLauncher, BootstrapErtsBin, Work),
    MakeEnvironment0 = case CrossCompiling of
        true -> with_external_bootstrap_path(BootstrapTools, BuildEnvironment);
        false -> with_otp_bootstrap_path(Source, BuildEnvironment)
    end,
    MakeEnvironment = MakeEnvironment0#{
        "ERLC_EMULATOR" => filename:join([Source, "bootstrap", "bin", "erl"])
    },
    %% Bootstrap through the declared native erlexec. A valid bootstrap
    %% runtime need not package OTP's bin/erl shell launcher, and a source-built
    %% output from this rule can therefore bootstrap the next OTP release.
    ExternalBootstrapEnvironment0 = maps:merge(MakeEnvironment0, BootstrapRuntimeEnvironment),
    ExternalBootstrapExecutionEnvironment = ExternalBootstrapEnvironment0#{
        "ERLC_EMULATOR" => BootstrapLauncher,
        "ESCRIPT_EMULATOR" => BootstrapLauncher,
        "RULES_ELIXIR_MIX_BOOTSTRAP_ERLEXEC" => BootstrapErlExec,
        "RULES_ELIXIR_MIX_BOOTSTRAP_ERTS_BIN" => BootstrapErtsBin,
        "RULES_ELIXIR_MIX_BOOTSTRAP_ROOT" => absolute(maps:get(bootstrap_root, Config))
    },
    %% GNU Make exports variables inherited from its environment. OTP reuses
    %% these names for target outputs, so importing the bootstrap values would
    %% make bare build-machine tools inherit the target runtime after Make
    %% reassigns them. Keep the Make-owned names out of that boundary. The
    %% declared recipe shell restores them only for child processes, and the
    %% bootstrap VM also receives them through ERL_AFLAGS -env.
    ExternalBootstrapEnvironment = ExternalBootstrapExecutionEnvironment#{
        "BINDIR" => false,
        "EMU" => false,
        "ERL_ROOTDIR" => false,
        "PROGNAME" => false,
        "ROOTDIR" => false
    },
    true = filelib:is_file(filename:join(BootstrapErtsBin, "beam.smp")),
    ok = run(
        BootstrapLauncher,
        ["-noshell", "-eval", "halt()."],
        Work,
        ExternalBootstrapExecutionEnvironment
    ),
    Jobs = integer_to_list(maps:get(jobs, Config)),
    MakeShellVariables = case CrossCompiling of
        true -> bootstrap_make_shell_variables(
            absolute(maps:get(env, Config)),
            maps:get("SHELL", MakeEnvironment),
            BootstrapRuntimeEnvironment
        );
        false -> ["SHELL=" ++ maps:get("SHELL", MakeEnvironment)]
    end,
    MakeDeterministic = "ERL_DETERMINISTIC=yes",
    MakePath = "PATH=" ++ maps:get("PATH", MakeEnvironment0),
    MakeTarget = "TARGET=" ++ otp_target(Source),
    %% OTP's generated Makefiles assign ARFLAGS themselves, so the action's
    %% environment alone cannot carry the C/C++ toolchain's deterministic
    %% archive policy. A command-line assignment has Make's required priority.
    MakeArFlags = "ARFLAGS=" ++ maps:get("ARFLAGS", MakeEnvironment),
    %% OTP's export-symbol configure probe temporarily discards LDFLAGS. A
    %% hermetic linker needs the declared sysroot and driver selection retained
    %% there, so the probe can report a false negative. Set OTP's dedicated
    %% emulator-link variable to the upstream Linux value; dynamically loaded
    %% NIFs resolve the public enif_* API from beam.smp through these exports.
    MakeExport = "DEXPORT=-Wl,-export-dynamic",
    BootstrapMakeVariables = bootstrap_make_variables(
        absolute(maps:get(env, Config)),
        BootstrapLauncher,
        BootstrapErtsBin,
        BootstrapRuntimeEnvironment
    ),
    MakeVariables0 = MakeShellVariables ++ [
        MakeDeterministic,
        MakeArFlags,
        MakeExport,
        MakePath,
        MakeTarget
    ],
    %% Every cross-build Make traversal must resolve build tools from the
    %% declared bootstrap runtime. CROSS_COMPILING propagates through recursive
    %% Make calls so OTP selects its bootstrap yielding_c_fun generator, while
    %% an empty BOOT_PREFIX prevents the target bootstrap/bin from entering PATH.
    %% Bind the upstream ERL/ERLC/ESCRIPT variables to the execution-platform
    %% runtime as command-line variables so they retain precedence in recursive
    %% Make calls. The declared env executable restores the bootstrap runtime
    %% fields at each invocation; OTP's Makefiles legitimately reuse BINDIR for
    %% target outputs, so exporting that field alone is insufficient.
    MakeVariables = case CrossCompiling of
        true -> MakeVariables0 ++ ["CROSS_COMPILING=yes", "BOOT_PREFIX="] ++ BootstrapMakeVariables;
        false -> MakeVariables0
    end,
    MakeOptions = maps:get(make_options, Config),
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ ["-j" ++ Jobs] ++ MakeOptions ++ ["erl_interface"],
        Source,
        ExternalBootstrapEnvironment
    ),
    %% OTP's static-NIF emulator graph can reach lib/crypto's archive target
    %% through two parallel recursive Make branches. Build that archive once
    %% at the boundary before the parallel emulator traversal; otherwise both
    %% archivers may write crypto.a concurrently.
    case StaticCryptoNif of
        true ->
            ok = run(
                maps:get(make, Config),
                MakeVariables ++ MakeOptions ++ ["-C", "lib/crypto", "static_lib"],
                Source,
                ExternalBootstrapEnvironment
            );
        false ->
            ok
    end,
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
    RuntimeBuildEnvironment = case CrossCompiling of
        true -> ExternalBootstrapEnvironment;
        false -> MakeEnvironment
    end,
    %% OTP's native build creates and executes bootstrap/bin/erl while building
    %% its secondary and tertiary compilers. Its cross-build graph deliberately
    %% excludes that target: bootstrap/bin/erl is backed by the target erlexec,
    %% which must never execute on the build platform. Cross builds keep using
    %% the declared build-machine OTP from BootstrapTools for every BEAM step.
    case CrossCompiling of
        true ->
            ok;
        false ->
            ok = run(
                maps:get(make, Config),
                MakeVariables ++ ["-j" ++ Jobs] ++ MakeOptions ++ ["bootstrap_setup"],
                Source,
                ExternalBootstrapEnvironment
            ),
            ok = run(
                maps:get(make, Config),
                MakeVariables ++ ["-j" ++ Jobs] ++ PgoMakeOptions ++ MakeOptions ++ ["all_bootstraps"],
                Source,
                RuntimeBuildEnvironment
            )
    end,
    FinalBuildTargets = case CrossCompiling of
        true -> ["depend", "erl_interface", "emulator", "erts", "libs", "start_scripts", "check_dev_rt_dep"];
        false -> []
    end,
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ ["-j" ++ Jobs] ++ PgoMakeOptions ++ MakeOptions ++ FinalBuildTargets,
        Source,
        RuntimeBuildEnvironment
    ),
    ok = run(
        maps:get(make, Config),
        MakeVariables ++ PgoMakeOptions ++ MakeOptions ++ ["install", "DESTDIR=" ++ Output],
        Source,
        RuntimeBuildEnvironment
    ),
    RuntimeRoot = filename:join([Output, "lib", "erlang"]),
    StableSource = "/rules_elixir_mix/sources/otp-" ++ maps:get(version, Config),
    ok = artifact_normalizer:prune_script_launchers(RuntimeRoot),
    %% OTP's DESTDIR install also creates top-level bin symlinks to the shell
    %% launchers under lib/erlang/bin. Those launchers are intentionally pruned;
    %% consumers invoke the separately declared native erlexec artifact.
    ok = remove(filename:join(Output, "bin")),
    ok = artifact_normalizer:normalize_tree(RuntimeRoot, Work, StableSource),
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
    ok = artifact_normalizer:assert_dynamic_symbols(
        filename:join(InstalledErtsBin, "beam.smp"),
        ["enif_alloc_resource", "enif_keep_resource"]
    ),
    case CrossCompiling of
        true -> ok;
        false ->
            VerificationEnvironment0 = activate_crypto(Config, Work, MakeEnvironment),
            VerificationEnvironment = runtime_environment(RuntimeRoot, InstalledErtsBin, VerificationEnvironment0),
            ok = verify_emu_flavor(
                maps:get(jit, Config, "auto"),
                InstalledErlExec,
                Work,
                VerificationEnvironment
            ),
            ok = verify_crypto(
                FipsRequired,
                StaticCryptoNif,
                InstalledErlExec,
                Work,
                VerificationEnvironment
            )
    end,
    ok = prune_loadable_crypto_nif(RuntimeRoot, StaticCryptoNif),
    case maps:get(crypto_build_elf_interpreter, Config, none) of
        none -> ok;
        _ -> artifact_normalizer:normalize_elf_runtime(
            RuntimeRoot,
            <<"/__rules_elixir_mix__/ld">>,
            <<"/__rules_elixir_mix__/lib">>
        )
    end,
    ok = artifact_normalizer:assert_declared_elf_closure(
        RuntimeRoot,
        crypto_dependency_roots(Config)
    ),
    case maps:get(crypto_execution_wrapper, Config, none) of
        none ->
            true = maps:get(native_fully_static, Config),
            ok = artifact_normalizer:assert_static_executables(RuntimeRoot);
        RuntimeWrapper0 ->
            false = maps:get(native_fully_static, Config),
            RuntimeWrapper = absolute_build_path(RuntimeWrapper0, ExecutionRoot),
            ok = artifact_normalizer:wrap_dynamic_executables(RuntimeRoot, RuntimeWrapper),
            ok = artifact_normalizer:assert_wrapped_executables(RuntimeRoot)
    end,
    ok = ensure_real_frontend(RuntimeRoot, "escript"),
    ok = artifact_normalizer:assert_absent(RuntimeRoot, [Work, ExecutionRoot]),
    ok = link_erts_bin(
        InstalledErtsBin,
        ErtsBinOutput,
        Output,
        maps:get(crypto_execution_wrapper, Config, none),
        ExecutionRoot
    ),
    ok = link_erts_bin(
        InstalledErtsBin,
        ExecErtsBinOutput,
        Output,
        maps:get(crypto_execution_exec_wrapper, Config, none),
        ExecutionRoot
    ),
    ok = ensure_parent(ErlOutput),
    ok = remove(ErlOutput),
    ok = stage_erl_launcher(Config, ExecutionRoot, ErtsBinOutput, ErlOutput),
    ok = remove(Work),
    ok.

crypto_dependency_roots(Config) ->
    case maps:get(crypto_sdk, Config, none) of
        none -> [];
        Sysroot -> [absolute(Sysroot)]
    end.

stage_erl_launcher(Config, ExecutionRoot, ErtsBinOutput, ErlOutput) ->
    case maps:get(crypto_execution_wrapper, Config, none) of
        none ->
            RelativeErl = filename:join([filename:basename(ErtsBinOutput), "erlexec"]),
            file:make_symlink(RelativeErl, ErlOutput);
        Wrapper0 ->
            Wrapper = absolute_build_path(Wrapper0, ExecutionRoot),
            copy_executable(Wrapper, ErlOutput)
    end.

with_otp_bootstrap_path(Source, Environment) ->
    Target = otp_target(Source),
    BootstrapBin = filename:join([Source, "bin", Target]),
    PrimaryBootstrapBin = filename:join([Source, "bootstrap", "bin"]),
    Existing = maps:get("PATH", Environment, ""),
    Environment#{
        "PATH" => string:join([BootstrapBin, PrimaryBootstrapBin, Existing], ":")
    }.

stage_bootstrap_tools(BootstrapLauncher, BootstrapErtsBin, Work) ->
    Directory = filename:join(Work, "bootstrap_tools"),
    ok = ensure_directory(Directory),
    ok = file:make_symlink(BootstrapLauncher, filename:join(Directory, "erl")),
    lists:foreach(fun(Name) ->
        ok = file:make_symlink(
            filename:join(BootstrapErtsBin, Name),
            filename:join(Directory, Name)
        )
    end, ["erlc", "escript"]),
    Directory.

bootstrap_make_variables(Env, BootstrapLauncher, BootstrapErtsBin, RuntimeEnvironment) ->
    RuntimeKeys = ["BINDIR", "EMU", "ERL_ROOTDIR", "PROGNAME", "ROOTDIR", "RULES_ELIXIR_MIX_ERTS_PATH"],
    Prefix = [Env] ++ [
        Key ++ "=" ++ maps:get(Key, RuntimeEnvironment)
        || Key <- RuntimeKeys,
           maps:is_key(Key, RuntimeEnvironment)
    ],
    [
        "ERL=" ++ shell_join(Prefix ++ [BootstrapLauncher, "-boot", "start_clean"]),
        "ERLC=" ++ shell_join(Prefix ++ [
            "ERLC_EMULATOR=" ++ BootstrapLauncher,
            filename:join(BootstrapErtsBin, "erlc")
        ]) ++
            " $(ERLC_WFLAGS) $(ERLC_FLAGS)",
        "ERLC_EMULATOR=" ++ BootstrapLauncher,
        "ESCRIPT=" ++ shell_join(Prefix ++ [filename:join(BootstrapErtsBin, "escript")])
    ].

bootstrap_make_shell_variables(Env, Bash, RuntimeEnvironment) ->
    RuntimeKeys = ["BINDIR", "EMU", "ERL_ROOTDIR", "PROGNAME", "ROOTDIR", "RULES_ELIXIR_MIX_ERTS_PATH"],
    RuntimeAssignments = [
        Key ++ "=" ++ maps:get(Key, RuntimeEnvironment)
        || Key <- RuntimeKeys
    ],
    [
        "SHELL=" ++ Env,
        ".SHELLFLAGS=" ++ shell_join(RuntimeAssignments ++ [Bash, "-c"])
    ].

with_external_bootstrap_path(BootstrapTools, Environment) ->
    Existing = maps:get("PATH", Environment, ""),
    Environment#{"PATH" => string:join([BootstrapTools, Existing], ":")}.

verify_bootstrap_release(false, _TargetVersion) ->
    ok;
verify_bootstrap_release(true, TargetVersion) ->
    [TargetRelease | _] = string:tokens(TargetVersion, "."),
    case erlang:system_info(otp_release) of
        TargetRelease -> ok;
        BootstrapRelease -> erlang:error({bootstrap_otp_release_mismatch, TargetRelease, BootstrapRelease})
    end.

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

expand_path({path, Path}, ExecutionRoot) ->
    absolute_build_path(Path, ExecutionRoot);
expand_path({path_list, Paths}, ExecutionRoot) ->
    string:join([absolute_build_path(Path, ExecutionRoot) || Path <- Paths], ":");
expand_path(Value, _ExecutionRoot) ->
    Value.

expand_runtime_value(Value, ExecutionRoot) ->
    lists:flatten(string:replace(Value, "/proc/self/cwd/", ExecutionRoot ++ "/", all)).

compiler_flag_environment(Config, Environment, ExecutionRoot) ->
    CFlags = normalize_flags(maps:get(cflags, Config, []), ExecutionRoot),
    CxxFlags = normalize_flags(maps:get(cxxflags, Config, []), ExecutionRoot),
    CxxDriverFlags = normalize_flags(maps:get(cxx_driver_flags, Config, []), ExecutionRoot),
    LinkDriverFlags = normalize_flags(maps:get(ld_driver_flags, Config, []), ExecutionRoot),
    DynamicLinkDriverFlags = normalize_flags(
        maps:get(ded_ld_driver_flags, Config, []),
        ExecutionRoot
    ),
    DynamicFlags = shell_join(normalize_flags(maps:get(ded_ldflags, Config, []), ExecutionRoot)),
    DynamicLibraries = shell_join(normalize_flags(maps:get(ded_libs, Config, []), ExecutionRoot)),
    ExecutableFlags = crypto_executable_link_flags(
        Config,
        normalize_flags(maps:get(ldflags, Config, []), ExecutionRoot)
    ),
    Environment#{
        "ARFLAGS" => shell_join(normalize_flags(maps:get(arflags, Config, []), ExecutionRoot)),
        "CFLAGS" => shell_join(CFlags),
        "CPP" => shell_join([maps:get("CC", Environment), "-E" | CFlags]),
        "CXX" => shell_join([maps:get("CXX", Environment) | CxxDriverFlags]),
        "CXXFLAGS" => shell_join(CxxFlags),
        "DED_LD" => shell_join([
            absolute_build_path(maps:get(ded_ld, Config), ExecutionRoot)
            | DynamicLinkDriverFlags
        ]),
        "DED_LD_FLAG_RUNTIME_LIBRARY_PATH" => maps:get(ded_ld_runtime_library_path, Config),
        "DED_LIBS" => DynamicLibraries,
        "DED_LDFLAGS" => DynamicFlags,
        "DED_LDFLAGS_CONFTEST" => DynamicFlags,
        "LD" => shell_join([maps:get("LD", Environment) | LinkDriverFlags]),
        "LDFLAGS" => shell_join(ExecutableFlags)
    }.

crypto_executable_link_flags(#{crypto_sdk := none}, Flags) ->
    Flags;
crypto_executable_link_flags(Config, Flags) ->
    case maps:get(crypto_build_elf_interpreter, Config, none) of
        none -> Flags;
        BuildInterpreter ->
            Marker = "-Wl,--dynamic-linker=" ++ BuildInterpreter,
            case length([Flag || Flag <- Flags, Flag =:= Marker]) of
                1 -> ok;
                Count -> erlang:error({invalid_declared_loader_marker_count, Count, Flags})
            end,
            RuntimeDirectory = filename:join(absolute(maps:get(crypto_sdk, Config)), "lib"),
            Interpreter = filename:join(RuntimeDirectory, "ld-runtime.so.1"),
            true = filelib:is_file(Interpreter),
            Rewritten = [
                case Flag of
                    Marker ->
                        "-Wl,--dynamic-linker=" ++ Interpreter;
                    _ -> Flag
                end
             || Flag <- Flags
            ],
            Rewritten ++ ["-Wl,-rpath," ++ RuntimeDirectory]
    end.

cross_compile_environment(Config, Environment, ExecutionRoot) ->
    case maps:get(cross_compiling, Config, false) of
        false -> Environment;
        true ->
            Flags = normalize_flags(maps:get(cflags, Config, []), ExecutionRoot),
            Sysroots = lists:usort([
                lists:nthtail(length("--sysroot="), Flag)
                || Flag <- Flags,
                   lists:prefix("--sysroot=", Flag)
            ]),
            case Sysroots of
                [Sysroot] -> Environment#{
                    "erl_xcomp_isysroot" => Sysroot,
                    "erl_xcomp_sysroot" => Sysroot
                };
                _ -> erlang:error({cross_compile_requires_one_declared_sysroot, Sysroots})
            end
    end.

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
    LinkerSelector = "-fuse-ld=",
    Prefixes = [
        "--sysroot=",
        "--gcc-toolchain=",
        "-resource-dir=",
        "-Wl,--dynamic-linker=",
        "-Wl,-rpath,",
        "-isystem",
        "-I",
        "-L",
        "-B"
    ],
    case lists:prefix(LinkerSelector, Flag) andalso length(Flag) > length(LinkerSelector) of
        true ->
            Linker = lists:nthtail(length(LinkerSelector), Flag),
            case lists:member($/, Linker) of
                true -> LinkerSelector ++ absolute_build_path(Linker, ExecutionRoot);
                false -> Flag
            end;
        false ->
            normalize_prefixed_flag(Flag, Prefixes, ExecutionRoot)
    end.

normalize_prefixed_flag(Flag, [], ExecutionRoot) ->
    expand_runtime_value(Flag, ExecutionRoot);
normalize_prefixed_flag(Flag, [Prefix | Rest], ExecutionRoot) ->
    case lists:prefix(Prefix, Flag) andalso length(Flag) > length(Prefix) of
        true ->
            Path = lists:nthtail(length(Prefix), Flag),
            Prefix ++ absolute_build_path(Path, ExecutionRoot);
        false ->
            normalize_prefixed_flag(Flag, Rest, ExecutionRoot)
    end.

absolute_build_path(Path, ExecutionRoot) ->
    Marker = "/proc/self/cwd/",
    case lists:prefix(Marker, Path) of
        true -> filename:join(ExecutionRoot, lists:nthtail(length(Marker), Path));
        false ->
            case filename:pathtype(Path) of
                absolute -> Path;
                _ -> filename:join(ExecutionRoot, Path)
            end
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
    case maps:get(crypto_prepared_state, Config, none) of
        PreparedState when PreparedState =/= none ->
            Sysroot = absolute(maps:get(crypto_sdk, Config)),
            ActivationRoot = absolute(PreparedState),
            Expand = fun(Value) ->
                replace_template(Value, Sysroot, ActivationRoot)
            end,
            RuntimeEnvironment = maps:map(
                fun(_Key, Value) -> Expand(Value) end,
                maps:get(crypto_runtime_environment, Config, #{})
            ),
            maps:merge(Environment, RuntimeEnvironment);
        none -> activate_crypto_legacy(Config, Work, Environment)
    end.

activate_crypto_legacy(Config, _Work, Environment) ->
    case maps:get(crypto_activation_tool, Config, none) of
        none -> Environment;
        Tool -> erlang:error({crypto_activation_missing_prepared_state, Tool})
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

link_erts_bin(Source, Destination, InstallRoot, Wrapper0, ExecutionRoot) ->
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
    PublicChildren = [
        Child
        || Child <- Children,
           not lists:prefix(".real-", Child)
    ],
    RealChildren = [
        lists:nthtail(length(".real-"), Child)
        || Child <- Children,
           lists:prefix(".real-", Child)
    ],
    case Wrapper0 of
        none ->
            lists:foreach(
                fun(Child) ->
                    ok = file:make_symlink(
                        filename:join(RelativeSource, Child),
                        filename:join(Destination, Child)
                    )
                end,
                PublicChildren
            ),
            ok = link_erl_alias(Destination, PublicChildren, none);
        Wrapper0 ->
            Wrapper = absolute_build_path(Wrapper0, ExecutionRoot),
            Launcher = filename:join(Destination, ".runtime-launch"),
            ok = copy_executable(Wrapper, Launcher),
            lists:foreach(
                fun(Child) ->
                    case lists:member(Child, RealChildren) of
                        true ->
                            ok = file:make_symlink(
                                filename:join(RelativeSource, ".real-" ++ Child),
                                filename:join(Destination, ".real-" ++ Child)
                            ),
                            %% OTP deliberately changes BEAM's argv[0] to the calling
                            %% frontend (for example erlc via ESCRIPT_NAME). Give each
                            %% launcher name its own executable directory entry so the
                            %% static wrapper can dispatch by /proc/self/exe without
                            %% interpreting that application-visible argv[0]. Hard
                            %% links keep the action tree and CAS content deduplicated.
                            ok = file:make_link(Launcher, filename:join(Destination, Child));
                        false ->
                            ok = file:make_symlink(
                                filename:join(RelativeSource, Child),
                                filename:join(Destination, Child)
                            )
                    end
                end,
                PublicChildren
            ),
            ok = link_erl_alias(Destination, PublicChildren, Launcher)
    end.

ensure_real_frontend(RuntimeRoot, Name) ->
    Bin = filename:join(RuntimeRoot, "bin"),
    Frontend = filename:join(Bin, Name),
    RealFrontend = filename:join(Bin, ".real-" ++ Name),
    true = filelib:is_file(Frontend),
    case file:read_link_info(RealFrontend) of
        {ok, _} ->
            ok;
        {error, enoent} ->
            file:make_symlink(Name, RealFrontend);
        Error ->
            erlang:error({inspect_real_frontend, RealFrontend, Error})
    end.

link_erl_alias(Destination, Children, Wrapper) ->
    true = lists:member("erlexec", Children),
    case lists:member("erl", Children) of
        true -> ok;
        false ->
            case Wrapper of
                none ->
                    file:make_symlink("erlexec", filename:join(Destination, "erl"));
                _ ->
                    ok = file:make_symlink(
                        ".real-erlexec",
                        filename:join(Destination, ".real-erl")
                    ),
                    file:make_link(Wrapper, filename:join(Destination, "erl"))
            end
    end.

copy_executable(Source, Destination) ->
    {ok, SourceInfo} = file:read_file_info(Source),
    {ok, _Bytes} = file:copy(Source, Destination),
    {ok, DestinationInfo} = file:read_file_info(Destination),
    file:write_file_info(Destination, DestinationInfo#file_info{mode = SourceInfo#file_info.mode}).

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

verify_emu_flavor("auto", _InstalledErl, _Work, _Environment) ->
    ok;
verify_emu_flavor(Mode, InstalledErl, Work, Environment) ->
    Expected = case Mode of
        "disabled" -> "emu";
        "required" -> "jit"
    end,
    Expression =
        "Expected=" ++ Expected ++ "," ++
        "Expected=erlang:system_info(emu_flavor)," ++
        "io:format(\"verified OTP emulator flavor: ~tp~n\",[Expected])," ++
        "halt(0).",
    run(
        InstalledErl,
        ["-noshell", "-eval", Expression],
        Work,
        Environment
    ).

prune_loadable_crypto_nif(_RuntimeRoot, false) ->
    ok;
prune_loadable_crypto_nif(RuntimeRoot, true) ->
    %% OTP installs crypto.so even when the same NIF is linked statically into
    %% BEAM. Verify the static runtime first, then omit the redundant loadable
    %% copy so the delivered tree cannot fall back to it.
    Pattern = filename:join([RuntimeRoot, "lib", "crypto-*", "priv", "lib", "crypto.so"]),
    lists:foreach(fun(Path) -> ok = file:delete(Path) end, filelib:wildcard(Pattern)),
    ok.

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

print_log_tail(Path, Limit) ->
    case file:read_file(Path) of
        {ok, Contents} ->
            Lines = binary:split(Contents, <<"\n">>, [global]),
            Offset = max(0, length(Lines) - Limit),
            ok = io:put_chars(["\n--- ", Path, " (tail) ---\n"]),
            ok = io:put_chars(lists:join(<<"\n">>, lists:nthtail(Offset, Lines))),
            ok = io:put_chars("\n--- end config.log ---\n");
        {error, enoent} ->
            ok;
        {error, Error} ->
            erlang:error({config_log_read_failed, Path, Error})
    end.
