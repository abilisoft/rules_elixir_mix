-module(runtime_archive_driver_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

deterministic_otp_archive_test() ->
    Base = fresh_directory("deterministic"),
    Root = filename:join(Base, "runtime"),
    Erlexec = filename:join([Root, "erts-17.0.3", "bin", "erlexec"]),
    VersionMarker = filename:join([Root, "releases", "29", "OTP_VERSION"]),
    AppFile = filename:join([Root, "lib", "kernel-10.3", "ebin", "kernel.app"]),
    ok = write_file(Erlexec, static_elf()),
    ok = file:change_mode(Erlexec, 8#755),
    ok = write_file(VersionMarker, <<"29.0.3\n">>),
    ok = write_file(AppFile, <<"{application,kernel,[]}.\n">>),
    First = archive_paths(Base, "first"),
    Second = archive_paths(Base, "second"),
    ok = runtime_archive_driver:main(arguments(Root, First)),
    {ok, AppInfo} = file:read_file_info(AppFile),
    ok = file:write_file_info(AppFile, AppInfo#file_info{mtime = {{2038, 1, 1}, {0, 0, 0}}}),
    ok = runtime_archive_driver:main(arguments(Root, Second)),
    {ok, FirstArchive} = file:read_file(maps:get(archive, First)),
    {ok, SecondArchive} = file:read_file(maps:get(archive, Second)),
    ?assertEqual(FirstArchive, SecondArchive),
    {ok, DigestFile} = file:read_file(maps:get(sha256, First)),
    ?assertEqual(<<(hex(crypto:hash(sha256, FirstArchive)))/binary, "\n">>, DigestFile),
    {ok, Metadata} = file:read_file(maps:get(metadata, First)),
    ?assertNotEqual(nomatch, binary:match(Metadata, <<"\"kind\": \"otp\"">>)),
    ?assertNotEqual(nomatch, binary:match(Metadata, <<"\"erlexec\": \"erts-17.0.3/bin/erlexec\"">>)),
    ?assertNotEqual(nomatch, binary:match(Metadata, <<"\"otp_fully_static\": true">>)),
    {ok, Entries} = erl_tar:table(maps:get(archive, First), [compressed]),
    ?assert(lists:member("otp-29.0.3/erts-17.0.3/bin/erlexec", Entries)).

escaping_symlink_test() ->
    Base = fresh_directory("escaping_symlink"),
    Root = filename:join(Base, "runtime"),
    Erlexec = filename:join([Root, "erts-17.0.3", "bin", "erlexec"]),
    VersionMarker = filename:join([Root, "releases", "29", "OTP_VERSION"]),
    Escape = filename:join([Root, "lib", "escape"]),
    ok = write_file(Erlexec, static_elf()),
    ok = file:change_mode(Erlexec, 8#755),
    ok = write_file(VersionMarker, <<"29.0.3\n">>),
    ok = filelib:ensure_dir(Escape),
    ok = file:make_symlink("../../../outside", Escape),
    Paths = archive_paths(Base, "escape"),
    ?assertException(
        error,
        {declared_elf_symlink_escape, Escape, "../../../outside"},
        runtime_archive_driver:main(arguments(Root, Paths))
    ),
    ?assertNot(filelib:is_file(maps:get(archive, Paths))).

arguments(Root, Paths) ->
    [
        "otp",
        "29.0.3",
        "static",
        Root,
        Root,
        "otp-29.0.3",
        maps:get(archive, Paths),
        maps:get(sha256, Paths),
        maps:get(metadata, Paths)
    ].

archive_paths(Base, Name) ->
    #{
        archive => filename:join(Base, Name ++ ".tar.gz"),
        metadata => filename:join(Base, Name ++ ".metadata.json"),
        sha256 => filename:join(Base, Name ++ ".sha256")
    }.

fresh_directory(Name) ->
    Base = filename:join(os:getenv("TEST_TMPDIR"), "runtime_archive_" ++ Name),
    ok = remove(Base),
    ok = filelib:ensure_dir(filename:join(Base, ".keep")),
    Base.

write_file(Path, Contents) ->
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, Contents).

static_elf() ->
    <<16#7f, $E, $L, $F, 2, 1, 0:80,
      2:16/little, 62:16/little, 1:32/little, 0:64/little,
      64:64/little, 0:64/little, 0:32/little, 64:16/little,
      56:16/little, 0:16/little, 0:16/little, 0:16/little, 0:16/little>>.

hex(Binary) ->
    list_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Binary]).

remove(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> file:del_dir_r(Path);
        {ok, _Info} -> file:delete(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.
