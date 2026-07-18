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
