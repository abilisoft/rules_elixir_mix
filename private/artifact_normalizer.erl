%% Reproducibility checks for source-built OTP and Elixir artifacts.
-module(artifact_normalizer).
-export([normalize_tree/3, normalize_beams/3, prune_script_launchers/1,
         scrub_erts_build_metadata/1, scrub_erts_commandline_flags/1,
         assert_absent/2, assert_beams_absent/2]).

-include_lib("kernel/include/file.hrl").

normalize_tree(Root, From0, To0) ->
    From = iolist_to_binary(From0),
    To = iolist_to_binary(To0),
    walk(Root, fun(Path) -> normalize_file(Path, From, To) end).

normalize_beams(Root, From0, To0) ->
    From = iolist_to_binary(From0),
    To = iolist_to_binary(To0),
    walk(Root, fun(Path) ->
        case filename:extension(Path) of
            ".beam" -> normalize_beam(Path, From, To);
            _ -> ok
        end
    end).

prune_script_launchers(RuntimeRoot) ->
    walk(RuntimeRoot, fun prune_script_launcher/1).

prune_script_launcher(Path) ->
    case file:read_file(Path) of
        {ok, <<"#!", _/binary>>} -> ok = file:delete(Path);
        {ok, _} -> ok;
        {error, eisdir} -> ok;
        {error, enoent} -> ok;
        Error -> erlang:error({launcher_inspection_failed, Path, Error})
    end.

scrub_erts_commandline_flags(SourceRoot) ->
    Pattern = filename:join([SourceRoot, "erts", "*", "config.h"]),
    Configs = filelib:wildcard(Pattern),
    case Configs of
        [] -> erlang:error({missing_generated_erts_config, Pattern});
        _ -> lists:foreach(fun scrub_erts_config/1, Configs)
    end,
    ok.

scrub_erts_build_metadata(SourceRoot) ->
    Pattern = filename:join([SourceRoot, "erts", "emulator", "*", "Makefile"]),
    Makefiles = [
        Path
        || Path <- filelib:wildcard(Pattern),
           filename:basename(filename:dirname(Path)) =/= "test"
    ],
    case Makefiles of
        [] -> erlang:error({missing_generated_emulator_makefile, Pattern});
        _ -> lists:foreach(fun scrub_emulator_makefile/1, Makefiles)
    end,
    ok.

assert_absent(Root, Prefixes0) ->
    Prefixes = [iolist_to_binary(Prefix) || Prefix <- Prefixes0],
    walk(Root, fun(Path) -> assert_file_absent(Path, Prefixes) end).

assert_beams_absent(Root, Prefixes0) ->
    Prefixes = [iolist_to_binary(Prefix) || Prefix <- Prefixes0],
    walk(Root, fun(Path) ->
        case filename:extension(Path) of
            ".beam" -> assert_file_absent(Path, Prefixes);
            _ -> ok
        end
    end).

walk(Path, Function) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Children} = file:list_dir(Path),
            lists:foreach(
                fun(Child) -> walk(filename:join(Path, Child), Function) end,
                lists:sort(Children)
            );
        {ok, #file_info{type = regular}} ->
            Function(Path);
        {ok, #file_info{type = symlink}} ->
            ok;
        {ok, _Info} ->
            ok;
        Error ->
            erlang:error({artifact_walk_failed, Path, Error})
    end.

normalize_file(Path, From, To) ->
    case filename:extension(Path) of
        ".beam" ->
            normalize_beam(Path, From, To);
        _ ->
            {ok, Content} = file:read_file(Path),
            case binary:match(Content, From) of
                nomatch -> ok;
                _ ->
                    case binary:match(Content, <<0>>) of
                        nomatch -> file:write_file(Path, binary:replace(Content, From, To, [global]));
                        _ -> erlang:error({unstable_binary_artifact, Path, binary_to_list(From)})
                    end
            end
    end.

normalize_beam(Path, From, To) ->
    {ok, _Module, Chunks} = beam_lib:all_chunks(Path),
    Normalized = [normalize_chunk(Path, Chunk, From, To) || Chunk <- Chunks],
    {ok, Beam} = beam_lib:build_module(Normalized),
    ok = file:write_file(Path, Beam).

normalize_chunk(_Path, {"LitT", Data}, From, To) ->
    {"LitT", normalize_literals(Data, From, To)};
normalize_chunk(Path, {Id, Data}, From, To)
        when Id =:= "Attr"; Id =:= "CInf"; Id =:= "Dbgi";
             Id =:= "Docs"; Id =:= "ExCk" ->
    try binary_to_term(Data) of
        Term -> {Id, encode_term_like(Data, rewrite_term(Term, From, To))}
    catch
        error:badarg ->
            case binary:match(Data, From) of
                nomatch -> {Id, Data};
                _ -> erlang:error({unstable_beam_chunk, Path, Id})
            end
    end;
normalize_chunk(Path, {Id, Data}, From, _To) ->
    case binary:match(Data, From) of
        nomatch -> {Id, Data};
        _ -> erlang:error({unstable_beam_chunk, Path, Id})
    end.

encode_term_like(<<131, 80, _/binary>>, Term) ->
    term_to_binary(Term, [compressed, deterministic]);
encode_term_like(_Data, Term) ->
    %% Preserve uncompressed metadata chunks such as Attr and CInf; the VM
    %% loader consumes their external-term representation directly.
    term_to_binary(Term, [deterministic]).

normalize_literals(<<0:32/big, Table/binary>>, From, To) ->
    <<0:32/big, (normalize_literal_table(Table, From, To))/binary>>;
normalize_literals(<<_OriginalSize:32/big, Compressed/binary>>, From, To) ->
    Uncompressed = normalize_literal_table(zlib:uncompress(Compressed), From, To),
    CompressedResult = zlib:compress(Uncompressed),
    <<(byte_size(Uncompressed)):32/big, CompressedResult/binary>>.

normalize_literal_table(<<Count:32/big, Entries/binary>>, From, To) ->
    {NormalizedEntries, <<>>} = normalize_literal_entries(Count, Entries, From, To, []),
    iolist_to_binary([<<Count:32/big>>, lists:reverse(NormalizedEntries)]).

normalize_literal_entries(0, Rest, _From, _To, Accumulator) ->
    {Accumulator, Rest};
normalize_literal_entries(Count, <<Size:32/big, Encoded:Size/binary, Rest/binary>>, From, To, Accumulator) ->
    Term = binary_to_term(Encoded),
    Normalized = term_to_binary(rewrite_term(Term, From, To), [deterministic]),
    normalize_literal_entries(
        Count - 1,
        Rest,
        From,
        To,
        [[<<(byte_size(Normalized)):32/big>>, Normalized] | Accumulator]
    ).

rewrite_term(Value, From, To) when is_binary(Value) ->
    binary:replace(Value, From, To, [global]);
rewrite_term(Value, From, To) when is_list(Value) ->
    case byte_list(Value) of
        {true, Binary} -> binary_to_list(binary:replace(Binary, From, To, [global]));
        false -> rewrite_list(Value, From, To)
    end;
rewrite_term(Value, From, To) when is_tuple(Value) ->
    list_to_tuple([rewrite_term(Element, From, To) || Element <- tuple_to_list(Value)]);
rewrite_term(Value, From, To) when is_map(Value) ->
    maps:from_list([
        {rewrite_term(Key, From, To), rewrite_term(MapValue, From, To)}
        || {Key, MapValue} <- maps:to_list(Value)
    ]);
rewrite_term(Value, _From, _To) ->
    Value.

rewrite_list([], _From, _To) ->
    [];
rewrite_list([Head | Tail], From, To) ->
    [rewrite_term(Head, From, To) | rewrite_list_tail(Tail, From, To)].

rewrite_list_tail([], _From, _To) ->
    [];
rewrite_list_tail([_Head | _Tail] = Value, From, To) ->
    rewrite_list(Value, From, To);
rewrite_list_tail(Value, From, To) ->
    rewrite_term(Value, From, To).

byte_list(Value) ->
    byte_list(Value, []).

byte_list([], Accumulator) ->
    {true, list_to_binary(lists:reverse(Accumulator))};
byte_list([Byte | Rest], Accumulator)
        when is_integer(Byte), Byte >= 0, Byte =< 255 ->
    byte_list(Rest, [Byte | Accumulator]);
byte_list(_Value, _Accumulator) ->
    false.

scrub_erts_config(Path) ->
    {ok, Content} = file:read_file(Path),
    Lines = binary:split(Content, <<"\n">>, [global]),
    Prefix = <<"#define ERTS_EMU_CMDLINE_FLAGS ">>,
    Normalized = [
        case binary:match(Line, Prefix) of
            {0, _} ->
                <<"#define ERTS_EMU_CMDLINE_FLAGS \"rules_elixir_mix hermetic OTP build\"">>;
            _ -> Line
        end
        || Line <- Lines
    ],
    file:write_file(Path, lists:join(<<"\n">>, Normalized)).

scrub_emulator_makefile(Path) ->
    {ok, Content} = file:read_file(Path),
    Needle = <<"-v CFLAGS \"$(CFLAGS)\" -v LDFLAGS \"$(LDFLAGS)\"">>,
    Replacement = <<"-v CFLAGS \"rules_elixir_mix hermetic OTP build\" "
                    "-v LDFLAGS \"rules_elixir_mix hermetic OTP link\"">>,
    case binary:match(Content, Needle) of
        nomatch -> erlang:error({missing_erts_build_metadata_hook, Path});
        _ -> file:write_file(Path, binary:replace(Content, Needle, Replacement, [global]))
    end.

assert_file_absent(Path, Prefixes) ->
    {ok, Content} = file:read_file(Path),
    case [Prefix || Prefix <- Prefixes, binary:match(Content, Prefix) =/= nomatch] of
        [] -> ok;
        [Prefix | _] -> erlang:error({unstable_artifact_path, Path, binary_to_list(Prefix)})
    end.
