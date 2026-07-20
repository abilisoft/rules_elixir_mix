%% Reproducibility checks for source-built OTP and Elixir artifacts.
-module(artifact_normalizer).
-export([normalize_tree/3, normalize_beams/3, normalize_elf_runtime/3, prune_script_launchers/1,
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

normalize_elf_runtime(Root, Interpreter0, Runpath0) ->
    Interpreter = iolist_to_binary(Interpreter0),
    Runpath = iolist_to_binary(Runpath0),
    walk(Root, fun(Path) -> normalize_elf_file(Path, Interpreter, Runpath) end).

normalize_elf_file(Path, Interpreter, Runpath) ->
    {ok, Binary} = file:read_file(Path),
    case Binary of
        <<16#7f, $E, $L, $F, 2, 1, _/binary>> ->
            {ProgramOffset, SectionOffset, ProgramEntrySize, ProgramCount,
             SectionEntrySize, SectionCount} = elf_layout(Binary),
            WithInterpreter = normalize_elf_interpreter(
                Binary,
                ProgramOffset,
                ProgramEntrySize,
                ProgramCount,
                Interpreter
            ),
            Normalized = normalize_elf_runpaths(
                WithInterpreter,
                SectionOffset,
                SectionEntrySize,
                SectionCount,
                Runpath
            ),
            case Normalized =:= Binary of
                true -> ok;
                false -> file:write_file(Path, Normalized)
            end;
        <<16#7f, $E, $L, $F, _/binary>> ->
            erlang:error({unsupported_elf_format, Path});
        _ ->
            ok
    end.

elf_layout(Binary) ->
    <<16#7f, $E, $L, $F, 2, 1, _Ident:10/binary,
      _Type:16/little-unsigned-integer,
      _Machine:16/little-unsigned-integer,
      _Version:32/little-unsigned-integer,
      _Entry:64/little-unsigned-integer,
      ProgramOffset:64/little-unsigned-integer,
      SectionOffset:64/little-unsigned-integer,
      _Flags:32/little-unsigned-integer,
      _HeaderSize:16/little-unsigned-integer,
      ProgramEntrySize:16/little-unsigned-integer,
      ProgramCount:16/little-unsigned-integer,
      SectionEntrySize:16/little-unsigned-integer,
      SectionCount:16/little-unsigned-integer,
      _SectionNames:16/little-unsigned-integer,
      _/binary>> = Binary,
    {ProgramOffset, SectionOffset, ProgramEntrySize, ProgramCount,
     SectionEntrySize, SectionCount}.

normalize_elf_interpreter(Binary, _Offset, _EntrySize, 0, _Interpreter) ->
    Binary;
normalize_elf_interpreter(Binary, Offset, EntrySize, Count, Interpreter) ->
    Header = binary:part(Binary, Offset, EntrySize),
    <<Type:32/little-unsigned-integer,
      _Flags:32/little-unsigned-integer,
      FileOffset:64/little-unsigned-integer,
      _VirtualAddress:64/little-unsigned-integer,
      _PhysicalAddress:64/little-unsigned-integer,
      FileSize:64/little-unsigned-integer,
      _/binary>> = Header,
    Patched = case Type of
        3 -> replace_c_string(Binary, FileOffset, FileSize, Interpreter);
        _ -> Binary
    end,
    normalize_elf_interpreter(Patched, Offset + EntrySize, EntrySize, Count - 1, Interpreter).

normalize_elf_runpaths(Binary, SectionOffset, SectionEntrySize, SectionCount, Runpath) ->
    Sections = [
        elf_section(Binary, SectionOffset, SectionEntrySize, Index)
        || Index <- lists:seq(0, SectionCount - 1)
    ],
    lists:foldl(
        fun(Section, Accumulator) ->
            case maps:get(type, Section) of
                6 -> normalize_dynamic_runpaths(Accumulator, Section, Sections, Runpath);
                _ -> Accumulator
            end
        end,
        Binary,
        Sections
    ).

elf_section(Binary, SectionOffset, SectionEntrySize, Index) ->
    Offset = SectionOffset + Index * SectionEntrySize,
    Header = binary:part(Binary, Offset, SectionEntrySize),
    <<_Name:32/little-unsigned-integer,
      Type:32/little-unsigned-integer,
      _Flags:64/little-unsigned-integer,
      _Address:64/little-unsigned-integer,
      FileOffset:64/little-unsigned-integer,
      Size:64/little-unsigned-integer,
      Link:32/little-unsigned-integer,
      _Info:32/little-unsigned-integer,
      _Alignment:64/little-unsigned-integer,
      EntrySize:64/little-unsigned-integer,
      _/binary>> = Header,
    #{entry_size => EntrySize, link => Link, offset => FileOffset, size => Size, type => Type}.

normalize_dynamic_runpaths(Binary, Dynamic, Sections, Runpath) ->
    StringTable = lists:nth(maps:get(link, Dynamic) + 1, Sections),
    normalize_dynamic_entries(
        Binary,
        maps:get(offset, Dynamic),
        maps:get(size, Dynamic),
        maps:get(entry_size, Dynamic),
        maps:get(offset, StringTable),
        Runpath
    ).

normalize_dynamic_entries(_Binary, _Offset, _Remaining, 0, _StringsOffset, _Runpath) ->
    erlang:error(invalid_elf_dynamic_entry_size);
normalize_dynamic_entries(Binary, _Offset, Remaining, EntrySize, _StringsOffset, _Runpath)
        when Remaining < EntrySize ->
    Binary;
normalize_dynamic_entries(Binary, Offset, Remaining, EntrySize, StringsOffset, Runpath) ->
    Entry = binary:part(Binary, Offset, EntrySize),
    <<Tag:64/little-signed-integer, Value:64/little-unsigned-integer, _/binary>> = Entry,
    Patched = case Tag of
        15 -> replace_c_string(Binary, StringsOffset + Value, undefined, Runpath);
        29 -> replace_c_string(Binary, StringsOffset + Value, undefined, Runpath);
        _ -> Binary
    end,
    case Tag of
        0 -> Patched;
        _ -> normalize_dynamic_entries(
            Patched,
            Offset + EntrySize,
            Remaining - EntrySize,
            EntrySize,
            StringsOffset,
            Runpath
        )
    end.

replace_c_string(Binary, Offset, Capacity0, Replacement) ->
    Tail = binary:part(Binary, Offset, byte_size(Binary) - Offset),
    [Existing | _] = binary:split(Tail, <<0>>),
    ExistingCapacity = byte_size(Existing) + 1,
    Capacity = case Capacity0 of
        undefined -> ExistingCapacity;
        _ -> Capacity0
    end,
    true = Capacity >= ExistingCapacity,
    Required = byte_size(Replacement) + 1,
    case Required =< Capacity of
        true ->
            Padding = binary:copy(<<0>>, Capacity - byte_size(Replacement)),
            replace_bytes(Binary, Offset, Capacity, <<Replacement/binary, Padding/binary>>);
        false ->
            erlang:error({elf_runtime_path_too_long, binary_to_list(Existing), binary_to_list(Replacement)})
    end.

replace_bytes(Binary, Offset, Length, Replacement) ->
    <<Prefix:Offset/binary, _Old:Length/binary, Suffix/binary>> = Binary,
    <<Prefix/binary, Replacement/binary, Suffix/binary>>.

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
