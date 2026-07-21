%% SPDX-FileCopyrightText: 2026 AbiliSoft
%% SPDX-License-Identifier: Apache-2.0

%% Deterministic tar.gz producer for source-built OTP and Elixir runtimes.
-module(runtime_archive_driver).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([Kind, Version, NativeContract, DependencyRoot0, Root0, PackageDir, Archive0, Sha256Path0,
      MetadataPath0]) ->
    Root = normalized_absolute(Root0),
    DependencyRoot = normalized_absolute(DependencyRoot0),
    Archive = filename:absname(Archive0),
    Sha256Path = filename:absname(Sha256Path0),
    MetadataPath = filename:absname(MetadataPath0),
    ok = validate_package_dir(PackageDir),
    {ok, #file_info{type = directory}} = file:read_link_info(Root),
    ok = validate_native_contract(Kind, NativeContract, Root, DependencyRoot),
    Entries = collect(Root, ""),
    true = Entries =/= [],
    ok = ensure_parent(Archive),
    ok = remove(Archive),
    {ok, Tar} = erl_tar:open(Archive, [write, compressed]),
    try
        lists:foreach(
            fun({Relative, Path, Info}) ->
                ok = validate_symlink(Root, Path, Info),
                Name = filename:join(PackageDir, Relative),
                ok = erl_tar:add(Tar, Path, Name, normalized_options(Info))
            end,
            Entries
        ),
        ok = erl_tar:close(Tar)
    catch
        Class:Reason:Stacktrace ->
            _ = erl_tar:close(Tar),
            _ = remove(Archive),
            erlang:raise(Class, Reason, Stacktrace)
    end,
    {ok, _} = application:ensure_all_started(crypto),
    Digest = sha256(Archive),
    HexDigest = hex(Digest),
    ok = file:write_file(Sha256Path, [HexDigest, "\n"]),
    RuntimeMetadata = runtime_metadata(Kind, Version, NativeContract, Root),
    ok = file:write_file(
        MetadataPath,
        metadata_json(Kind, Version, PackageDir, filename:basename(Archive), HexDigest, RuntimeMetadata)
    ),
    ok.

validate_native_contract("otp", "static", Root, DependencyRoot) ->
    ok = artifact_normalizer:assert_static_executables(Root),
    artifact_normalizer:assert_declared_elf_closure(Root, [DependencyRoot]);
validate_native_contract("otp", "wrapped", Root, DependencyRoot) ->
    ok = artifact_normalizer:assert_wrapped_executables(Root),
    artifact_normalizer:assert_declared_elf_closure(Root, [DependencyRoot]);
validate_native_contract("otp", NativeContract, _Root, _DependencyRoot) ->
    erlang:error({unsupported_native_runtime_contract, NativeContract});
validate_native_contract("elixir", _NativeContract, _Root, _DependencyRoot) ->
    ok.

collect(Root, Relative) ->
    Directory = join_relative(Root, Relative),
    {ok, Names0} = file:list_dir(Directory),
    Names = lists:sort(Names0),
    case {Relative, Names} of
        {"", []} ->
            [];
        {_, []} ->
            {ok, Info} = file:read_link_info(Directory, [{time, posix}]),
            [{Relative, Directory, Info}];
        _ ->
            lists:append([
                collect_entry(Root, join_child(Relative, Name))
                || Name <- Names
            ])
    end.

collect_entry(Root, Relative) ->
    Path = filename:join(Root, Relative),
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, #file_info{type = directory}} -> collect(Root, Relative);
        {ok, #file_info{type = regular} = Info} -> [{Relative, Path, Info}];
        {ok, #file_info{type = symlink} = Info} -> [{Relative, Path, Info}];
        {ok, #file_info{type = Type}} -> erlang:error({unsupported_runtime_entry, Relative, Type});
        Error -> erlang:error({runtime_entry_failed, Relative, Error})
    end.

normalized_options(#file_info{type = regular, mode = Mode}) ->
    Executable = Mode band 8#111 =/= 0,
    normalized_times_and_owner(if Executable -> 8#755; true -> 8#644 end);
normalized_options(#file_info{type = directory}) ->
    normalized_times_and_owner(8#755);
normalized_options(#file_info{type = symlink}) ->
    normalized_times_and_owner(8#777).

normalized_times_and_owner(Mode) ->
    [
        {atime, 0},
        {mtime, 0},
        {ctime, 0},
        {uid, 0},
        {gid, 0},
        {mode, Mode}
    ].

validate_symlink(_Root, _Path, #file_info{type = Type}) when Type =/= symlink ->
    ok;
validate_symlink(Root, Path, #file_info{type = symlink}) ->
    {ok, Target} = file:read_link(Path),
    relative = filename:pathtype(Target),
    Resolved = normalized_absolute(filename:join(filename:dirname(Path), Target)),
    true = within(Root, Resolved),
    ok.

within(Root, Path) ->
    Path =:= Root orelse lists:prefix(Root ++ "/", Path).

normalized_absolute(Path) ->
    [Root | Parts] = filename:split(filename:absname(Path)),
    filename:join([Root | lists:reverse(normalize_parts(Parts, []))]).

normalize_parts([], Accumulator) ->
    Accumulator;
normalize_parts(["." | Rest], Accumulator) ->
    normalize_parts(Rest, Accumulator);
normalize_parts([".." | Rest], [_ | Accumulator]) ->
    normalize_parts(Rest, Accumulator);
normalize_parts([".." | Rest], []) ->
    normalize_parts(Rest, []);
normalize_parts([Part | Rest], Accumulator) ->
    normalize_parts(Rest, [Part | Accumulator]).

runtime_metadata("otp", Version, NativeContract, Root) ->
    ErlexecMatches = lists:sort(filelib:wildcard(filename:join([Root, "erts-*", "bin", "erlexec"]))),
    [Erlexec] = ErlexecMatches,
    Major = hd(string:tokens(Version, ".")),
    VersionMarker = filename:join(["releases", Major, "OTP_VERSION"]),
    ok = require_version(filename:join(Root, VersionMarker), Version),
    ContractMetadata = case NativeContract of
        "static" -> #{"otp_fully_static" => true};
        "wrapped" -> #{"otp_runtime_wrapped" => true};
        _ -> erlang:error({unsupported_native_runtime_contract, NativeContract})
    end,
    ContractMetadata#{"erlexec" => relative_to(Root, Erlexec), "otp_version_marker" => VersionMarker};
runtime_metadata("elixir", Version, _NativeContract, Root) ->
    HomeMarker = filename:join(["bin", ".runtime_root"]),
    VersionMarker = "VERSION",
    ok = require_version(filename:join(Root, HomeMarker), Version),
    ok = require_version(filename:join(Root, VersionMarker), Version),
    #{"elixir_home_marker" => HomeMarker, "elixir_version_marker" => VersionMarker};
runtime_metadata(Kind, _Version, _NativeContract, _Root) ->
    erlang:error({unsupported_runtime_kind, Kind}).

require_version(Path, Version) ->
    {ok, Contents} = file:read_file(Path),
    Version = string:trim(binary_to_list(Contents)),
    ok.

sha256(Path) ->
    {ok, File} = file:open(Path, [read, raw, binary]),
    try
        sha256(File, crypto:hash_init(sha256))
    after
        ok = file:close(File)
    end.

sha256(File, State) ->
    case file:read(File, 1024 * 1024) of
        {ok, Data} -> sha256(File, crypto:hash_update(State, Data));
        eof -> crypto:hash_final(State);
        Error -> erlang:error({archive_read_failed, Error})
    end.

hex(Binary) ->
    lists:flatten([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Binary]).

metadata_json(Kind, Version, PackageDir, Archive, Digest, RuntimeMetadata) ->
    RuntimeFields = string:join([
        json_string(Key) ++ ": " ++ json_value(maps:get(Key, RuntimeMetadata))
        || Key <- lists:sort(maps:keys(RuntimeMetadata))
    ], ",\n    "),
    [
        "{\n",
        "  \"archive\": ", json_string(Archive), ",\n",
        "  \"archive_type\": \"tar.gz\",\n",
        "  \"kind\": ", json_string(Kind), ",\n",
        "  \"package_dir\": ", json_string(PackageDir), ",\n",
        "  \"prebuilt_toolchain\": {\n    ", RuntimeFields, "\n  },\n",
        "  \"sha256\": ", json_string(Digest), ",\n",
        "  \"version\": ", json_string(Version), "\n",
        "}\n"
    ].

json_string(Value) ->
    [$", [json_character(Character) || Character <- Value], $"].

json_value(true) -> "true";
json_value(false) -> "false";
json_value(Value) -> json_string(Value).

json_character($") -> "\\\"";
json_character($\\) -> "\\\\";
json_character($\b) -> "\\b";
json_character($\f) -> "\\f";
json_character($\n) -> "\\n";
json_character($\r) -> "\\r";
json_character($\t) -> "\\t";
json_character(Character) when Character < 16#20 -> io_lib:format("\\u~4.16.0b", [Character]);
json_character(Character) -> Character.

validate_package_dir(PackageDir) ->
    relative = filename:pathtype(PackageDir),
    Parts = filename:split(PackageDir),
    true = Parts =/= [],
    true = lists:all(fun(Part) -> Part =/= "" andalso Part =/= "." andalso Part =/= ".." end, Parts),
    ok.

relative_to(Root, Path) ->
    true = within(Root, Path),
    lists:nthtail(length(Root) + 1, Path).

join_relative(Root, "") -> Root;
join_relative(Root, Relative) -> filename:join(Root, Relative).

join_child("", Name) -> Name;
join_child(Relative, Name) -> filename:join(Relative, Name).

ensure_parent(Path) ->
    filelib:ensure_dir(Path).

remove(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> file:del_dir_r(Path);
        {ok, _Info} -> file:delete(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.
