-module(artifact_normalizer_tests).
-include_lib("eunit/include/eunit.hrl").

-export([nested_iodata_literal/0, unstable_path/0]).

unstable_path() ->
    <<"/unstable/rules_elixir_mix/action/source/path">>.

nested_iodata_literal() ->
    [46, "ze.", []].

compressed_and_uncompressed_literals_test() ->
    From = unstable_path(),
    To = <<"/rules_elixir_mix/sources/test">>,
    {ok, ?MODULE, Chunks} = beam_lib:all_chunks(code:which(?MODULE)),
    {"LitT", LiteralChunk} = lists:keyfind("LitT", 1, Chunks),
    {"Attr", OriginalAttributes} = lists:keyfind("Attr", 1, Chunks),
    Table = literal_table(LiteralChunk),
    ?assertNotEqual(nomatch, binary:match(Table, From)),
    Temporary = os:getenv("TEST_TMPDIR"),
    Uncompressed = filename:join(Temporary, "normalizer_uncompressed.beam"),
    Compressed = filename:join(Temporary, "normalizer_compressed.beam"),
    ok = write_variant(Uncompressed, Chunks, <<0:32/big, Table/binary>>),
    ok = write_variant(
        Compressed,
        Chunks,
        <<(byte_size(Table)):32/big, (zlib:compress(Table))/binary>>
    ),
    ok = artifact_normalizer:normalize_beams(Uncompressed, From, To),
    ok = artifact_normalizer:normalize_beams(Compressed, From, To),
    lists:foreach(
        fun(Path) ->
            {ok, ?MODULE, NormalizedChunks} = beam_lib:all_chunks(Path),
            {"LitT", NormalizedLiteralChunk} = lists:keyfind("LitT", 1, NormalizedChunks),
            {"Attr", NormalizedAttributes} = lists:keyfind("Attr", 1, NormalizedChunks),
            NormalizedTable = literal_table(NormalizedLiteralChunk),
            ?assertEqual(nomatch, binary:match(NormalizedTable, From)),
            ?assertNotEqual(nomatch, binary:match(NormalizedTable, To)),
            ?assert(lists:member(nested_iodata_literal(), literal_terms(NormalizedTable))),
            ?assertEqual(
                external_term_encoding(OriginalAttributes),
                external_term_encoding(NormalizedAttributes)
            )
        end,
        [Uncompressed, Compressed]
    ).

prune_script_launchers_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Runtime = filename:join(Temporary, "otp_runtime"),
    RootScript = filename:join([Runtime, "bin", "erl"]),
    ErtsScript = filename:join([Runtime, "erts-17.0", "bin", "erl"]),
    AppScript = filename:join([Runtime, "lib", "dialyzer-6.0", "bin", "dialyzer"]),
    MiscScript = filename:join([Runtime, "misc", "format_man_pages"]),
    TopScript = filename:join(Runtime, "Install"),
    NativeErlExec = filename:join([Runtime, "erts-17.0", "bin", "erlexec"]),
    lists:foreach(
        fun(Path) ->
            ok = filelib:ensure_dir(Path),
            ok = file:write_file(Path, <<"#!/declared/bash\nexit 0\n">>)
        end,
        [RootScript, ErtsScript, AppScript, MiscScript, TopScript]
    ),
    ok = file:write_file(NativeErlExec, <<127, "ELF", 0, 1, 2, 3>>),
    ok = artifact_normalizer:prune_script_launchers(Runtime),
    ?assertNot(filelib:is_file(RootScript)),
    ?assertNot(filelib:is_file(ErtsScript)),
    ?assertNot(filelib:is_file(AppScript)),
    ?assertNot(filelib:is_file(MiscScript)),
    ?assertNot(filelib:is_file(TopScript)),
    ?assert(filelib:is_file(NativeErlExec)).

scrub_erts_build_metadata_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Source = filename:join(Temporary, "otp_sources"),
    Config = filename:join([Source, "erts", "x86_64-test-linux-gnu", "config.h"]),
    Makefile = filename:join([Source, "erts", "emulator", "x86_64-test-linux-gnu", "Makefile"]),
    ok = filelib:ensure_dir(Config),
    ok = file:write_file(
        Config,
        <<"#define ERTS_EMU_CMDLINE_FLAGS \"-I/unstable/action/path\"\n#define KEEP 1\n">>
    ),
    ok = filelib:ensure_dir(Makefile),
    ok = file:write_file(
        Makefile,
        <<"TMPVAR := $(shell tool -v CFLAGS \"$(CFLAGS)\" -v LDFLAGS \"$(LDFLAGS)\")\n">>
    ),
    ok = artifact_normalizer:scrub_erts_commandline_flags(Source),
    ok = artifact_normalizer:scrub_erts_build_metadata(Source),
    {ok, ConfigContent} = file:read_file(Config),
    {ok, MakeContent} = file:read_file(Makefile),
    ?assertEqual(nomatch, binary:match(ConfigContent, <<"/unstable/action/path">>)),
    ?assertEqual(nomatch, binary:match(MakeContent, <<"$(CFLAGS)">>)),
    ?assertNotEqual(nomatch, binary:match(MakeContent, <<"hermetic OTP build">>)).

dynamic_executable_wrapping_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Runtime = filename:join(Temporary, "wrapped_runtime"),
    Program = filename:join([Runtime, "lib", "os_mon-2.12", "priv", "bin", "cpu_sup"]),
    Wrapper = filename:join(Temporary, "static_runtime_wrapper"),
    _ = file:del_dir_r(Runtime),
    _ = file:delete(Wrapper),
    ok = filelib:ensure_dir(Program),
    ok = file:write_file(Program, elf_executable(1)),
    ok = file:write_file(Wrapper, elf_executable(0)),
    ok = file:change_mode(Program, 8#755),
    ok = file:change_mode(Wrapper, 8#755),
    ok = artifact_normalizer:wrap_dynamic_executables(Runtime, Wrapper),
    Real = filename:join(filename:dirname(Program), ".real-cpu_sup"),
    ?assert(filelib:is_file(Program)),
    ?assert(filelib:is_file(Real)),
    ok = artifact_normalizer:assert_wrapped_executables(Runtime),
    ?assertException(
        error,
        {dynamic_executable_in_static_runtime, Real},
        artifact_normalizer:assert_static_executables(Runtime)
    ).

declared_elf_closure_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Runtime = filename:join(Temporary, "elf_closure_runtime"),
    Sdk = filename:join(Temporary, "elf_closure_sdk"),
    Plugin = filename:join([Runtime, "lib", "example-1", "priv", "example.so"]),
    Dependency = filename:join([Sdk, "lib", "libdeclared.so"]),
    Transitive = filename:join([Sdk, "lib", "libtransitive.so"]),
    _ = file:del_dir_r(Runtime),
    _ = file:del_dir_r(Sdk),
    ok = filelib:ensure_dir(Plugin),
    ok = filelib:ensure_dir(Dependency),
    ok = file:write_file(Plugin, elf_library(["libdeclared.so"])),
    ok = file:write_file(Dependency, elf_library(["libtransitive.so"])),
    ok = file:write_file(Transitive, elf_library([])),
    ok = artifact_normalizer:assert_declared_elf_closure(Runtime, [Sdk]).

undeclared_transitive_elf_dependency_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Runtime = filename:join(Temporary, "missing_elf_runtime"),
    Sdk = filename:join(Temporary, "missing_elf_sdk"),
    Plugin = filename:join([Runtime, "lib", "example-1", "priv", "example.so"]),
    Dependency = filename:join([Sdk, "lib", "libdeclared.so"]),
    _ = file:del_dir_r(Runtime),
    _ = file:del_dir_r(Sdk),
    ok = filelib:ensure_dir(Plugin),
    ok = filelib:ensure_dir(Dependency),
    ok = file:write_file(Plugin, elf_library(["libdeclared.so"])),
    ok = file:write_file(Dependency, elf_library(["libmissing.so"])),
    ?assertException(
        error,
        {undeclared_elf_dependency, Dependency, "libmissing.so"},
        artifact_normalizer:assert_declared_elf_closure(Runtime, [Sdk])
    ).

ambiguous_declared_elf_dependency_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Runtime = filename:join(Temporary, "ambiguous_elf_runtime"),
    Sdk = filename:join(Temporary, "ambiguous_elf_sdk"),
    Plugin = filename:join([Runtime, "lib", "example-1", "priv", "example.so"]),
    First = filename:join([Sdk, "lib", "libdeclared.so"]),
    Second = filename:join([Sdk, "usr", "lib", "libdeclared.so"]),
    _ = file:del_dir_r(Runtime),
    _ = file:del_dir_r(Sdk),
    ok = filelib:ensure_dir(Plugin),
    ok = filelib:ensure_dir(First),
    ok = filelib:ensure_dir(Second),
    ok = file:write_file(Plugin, elf_library(["libdeclared.so"])),
    ok = file:write_file(First, elf_library([])),
    ok = file:write_file(Second, elf_library([])),
    Candidates = lists:sort([First, Second]),
    ?assertException(
        error,
        {ambiguous_elf_dependency, Plugin, "libdeclared.so", Candidates},
        artifact_normalizer:assert_declared_elf_closure(Runtime, [Sdk])
    ).

contained_relative_elf_symlink_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Runtime = filename:join(Temporary, "symlink_elf_runtime"),
    Sdk = filename:join(Temporary, "symlink_elf_sdk"),
    Plugin = filename:join([Runtime, "lib", "example-1", "priv", "example.so"]),
    Dependency = filename:join([Sdk, "lib", "libdeclared.so.1"]),
    Alias = filename:join([Sdk, "lib", "libdeclared.so"]),
    _ = file:del_dir_r(Runtime),
    _ = file:del_dir_r(Sdk),
    ok = filelib:ensure_dir(Plugin),
    ok = filelib:ensure_dir(Dependency),
    ok = file:write_file(Plugin, elf_library(["libdeclared.so"])),
    ok = file:write_file(Dependency, elf_library([])),
    ok = file:make_symlink("libdeclared.so.1", Alias),
    ok = artifact_normalizer:assert_declared_elf_closure(Runtime, [Sdk]).

absolute_elf_symlink_rejected_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Runtime = filename:join(Temporary, "absolute_symlink_elf_runtime"),
    Sdk = filename:join(Temporary, "absolute_symlink_elf_sdk"),
    Plugin = filename:join([Runtime, "lib", "example-1", "priv", "example.so"]),
    Alias = filename:join([Sdk, "lib", "libdeclared.so"]),
    _ = file:del_dir_r(Runtime),
    _ = file:del_dir_r(Sdk),
    ok = filelib:ensure_dir(Plugin),
    ok = filelib:ensure_dir(Alias),
    ok = file:write_file(Plugin, elf_library(["libdeclared.so"])),
    ok = file:make_symlink("/usr/lib/libdeclared.so", Alias),
    ?assertException(
        error,
        {absolute_declared_elf_symlink, Alias, "/usr/lib/libdeclared.so"},
        artifact_normalizer:assert_declared_elf_closure(Runtime, [Sdk])
    ).

contained_non_elf_symlinks_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Root = filename:join(Temporary, "contained_non_elf_symlinks"),
    Target = filename:join([Root, "lib", "data.txt"]),
    Alias = filename:join([Root, "priv", "data.txt"]),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(Target),
    ok = filelib:ensure_dir(Alias),
    ok = file:write_file(Target, <<"declared">>),
    ok = file:make_symlink("../lib/data.txt", Alias),
    ok = artifact_normalizer:assert_contained_symlinks(Root).

escaping_non_elf_symlink_rejected_test() ->
    Temporary = os:getenv("TEST_TMPDIR"),
    Root = filename:join(Temporary, "escaping_non_elf_symlink"),
    Alias = filename:join([Root, "priv", "data.txt"]),
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_dir(Alias),
    ok = file:make_symlink("../../../outside", Alias),
    ?assertException(
        error,
        {declared_elf_symlink_escape, Alias, "../../../outside"},
        artifact_normalizer:assert_contained_symlinks(Root)
    ).

elf_executable(ProgramCount) ->
    ProgramHeader = case ProgramCount of
        0 -> <<>>;
        1 -> <<3:32/little, 5:32/little, 120:64/little, 0:64/little, 0:64/little,
               0:64/little, 0:64/little, 1:64/little>>
    end,
    <<16#7f, $E, $L, $F, 2, 1, 0:80,
      2:16/little, 62:16/little, 1:32/little, 0:64/little,
      64:64/little, 0:64/little, 0:32/little, 64:16/little,
      56:16/little, ProgramCount:16/little, 0:16/little, 0:16/little, 0:16/little,
      ProgramHeader/binary>>.

elf_library([]) ->
    <<16#7f, $E, $L, $F, 2, 1, 0:80,
      3:16/little, 62:16/little, 1:32/little, 0:64/little,
      0:64/little, 0:64/little, 0:32/little, 64:16/little,
      0:16/little, 0:16/little, 64:16/little, 0:16/little, 0:16/little>>;
elf_library(Dependencies) ->
    Strings = iolist_to_binary([[0], lists:join(<<0>>, Dependencies), [0]]),
    {Offsets, _Next} = lists:mapfoldl(
        fun(Dependency, Offset) -> {Offset, Offset + length(Dependency) + 1} end,
        1,
        Dependencies
    ),
    DynamicEntries = iolist_to_binary([
        [<<1:64/little-signed, Offset:64/little>> || Offset <- Offsets],
        <<0:64/little-signed, 0:64/little>>
    ]),
    SectionsOffset = 64,
    StringsOffset = SectionsOffset + 3 * 64,
    DynamicOffset = StringsOffset + byte_size(Strings),
    Header = <<16#7f, $E, $L, $F, 2, 1, 0:80,
      3:16/little, 62:16/little, 1:32/little, 0:64/little,
      0:64/little, SectionsOffset:64/little, 0:32/little, 64:16/little,
      0:16/little, 0:16/little, 64:16/little, 3:16/little, 0:16/little>>,
    NullSection = <<0:512>>,
    StringSection = elf_section_header(3, StringsOffset, byte_size(Strings), 0, 0),
    DynamicSection = elf_section_header(6, DynamicOffset, byte_size(DynamicEntries), 1, 16),
    <<Header/binary, NullSection/binary, StringSection/binary, DynamicSection/binary,
      Strings/binary, DynamicEntries/binary>>.

elf_section_header(Type, Offset, Size, Link, EntrySize) ->
    <<0:32/little, Type:32/little, 0:64/little, 0:64/little,
      Offset:64/little, Size:64/little, Link:32/little, 0:32/little,
      1:64/little, EntrySize:64/little>>.

literal_table(<<0:32/big, Table/binary>>) ->
    Table;
literal_table(<<_Size:32/big, Compressed/binary>>) ->
    zlib:uncompress(Compressed).

external_term_encoding(<<131, 80, _/binary>>) ->
    compressed;
external_term_encoding(<<131, _/binary>>) ->
    uncompressed.

literal_terms(<<Count:32/big, Entries/binary>>) ->
    literal_terms(Count, Entries, []).

literal_terms(0, <<>>, Accumulator) ->
    lists:reverse(Accumulator);
literal_terms(Count, <<Size:32/big, Encoded:Size/binary, Rest/binary>>, Accumulator) ->
    literal_terms(Count - 1, Rest, [binary_to_term(Encoded) | Accumulator]).

write_variant(Path, Chunks, LiteralChunk) ->
    {ok, Beam} = beam_lib:build_module(lists:keyreplace("LitT", 1, Chunks, {"LitT", LiteralChunk})),
    file:write_file(Path, Beam).
