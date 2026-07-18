%% Shell-free direct Erlang application compiler.
-module(erlang_app_driver).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([ConfigPath]) ->
    {ok, [Config]} = file:consult(ConfigPath),
    Output = maps:get(output, Config),
    App = maps:get(app, Config),
    AppRoot = filename:join(Output, App),
    Ebin = filename:join(AppRoot, "ebin"),
    Generated = filename:join(Output ++ ".work", "generated"),
    ok = remove(Output),
    ok = remove(Output ++ ".work"),
    ok = ensure_directory(Ebin),
    ok = ensure_directory(Generated),
    GeneratedSources = lists:flatmap(
        fun(Source) -> generate_source(Source, Generated) end,
        maps:get(sources, Config)
    ),
    ErlangSources = [
        Source
     || Source <- maps:get(sources, Config) ++ GeneratedSources,
        filename:extension(Source) =:= ".erl"
    ],
    IncludeOptions = [{i, Directory} || Directory <- maps:get(include_dirs, Config)],
    SourceInfo = [source_info(Source, maps:get(include_dirs, Config)) || Source <- ErlangSources],
    OrderedSources = order_sources(SourceInfo),
    InternalModules = [Module || {_Source, Module, _Transforms} <- SourceInfo],
    TransformModules = lists:usort([
        Transform
     || {_Source, _Module, Transforms} <- SourceInfo,
        Transform <- Transforms,
        lists:member(Transform, InternalModules)
    ]),
    true = code:add_patha(Ebin),
    CompileOptions = [deterministic, debug_info, report_errors, report_warnings, {outdir, Ebin}] ++
        option(maps:get(warnings_as_errors, Config), warnings_as_errors) ++ IncludeOptions,
    Modules = lists:sort([
        compile_source(Source, CompileOptions, TransformModules)
     || {Source, _Module, _Transforms} <- OrderedSources
    ]),
    ok = write_application(Config, Ebin, Modules),
    ok = stage_entries(maps:get(headers, Config, []), filename:join(AppRoot, "include")),
    ok = stage_priv(maps:get(priv, Config), filename:join(AppRoot, "priv")),
    ok = write_fingerprint(AppRoot, maps:get(fingerprint, Config)),
    ok = remove(Output ++ ".work"),
    ok.

generate_source(Source, Generated) ->
    case filename:extension(Source) of
        ".xrl" -> [generated_file(leex:file(Source, [{outdir, Generated}, report_errors, report_warnings]))];
        ".yrl" -> [generated_file(yecc:file(Source, [{outdir, Generated}, report_errors, report_warnings]))];
        _ -> []
    end.

generated_file({ok, File}) -> File;
generated_file({ok, File, _Warnings}) -> File;
generated_file(Error) -> erlang:error({source_generation_failed, Error}).

source_info(Source, IncludeDirectories) ->
    case epp:parse_file(Source, IncludeDirectories, []) of
        {ok, Forms} ->
            Module = hd([Name || {attribute, _Line, module, Name} <- Forms]),
            Transforms = lists:usort(lists:flatmap(
                fun
                    ({attribute, _Line, compile, Value}) -> parse_transforms(Value);
                    (_) -> []
                end,
                Forms
            )),
            {Source, Module, Transforms};
        Error ->
            erlang:error({source_parse_failed, Source, Error})
    end.

parse_transforms({parse_transform, Module}) when is_atom(Module) -> [Module];
parse_transforms(Options) when is_list(Options) -> lists:flatmap(fun parse_transforms/1, Options);
parse_transforms(_Option) -> [].

order_sources(SourceInfo) ->
    Internal = [Module || {_Source, Module, _Transforms} <- SourceInfo],
    order_sources(SourceInfo, Internal, [], []).

order_sources([], _Internal, _ReadyModules, Ordered) ->
    lists:reverse(Ordered);
order_sources(Pending, Internal, ReadyModules, Ordered) ->
    Ready = [
        Info
     || Info = {_Source, _Module, Transforms} <- Pending,
        lists:all(
            fun(Transform) ->
                not lists:member(Transform, Internal) orelse lists:member(Transform, ReadyModules)
            end,
            Transforms
        )
    ],
    case Ready of
        [] -> erlang:error({parse_transform_cycle, Pending});
        _ ->
            ReadySet = [{Source, Module} || {Source, Module, _Transforms} <- Ready],
            Remaining = [
                Info
             || Info = {Source, Module, _Transforms} <- Pending,
                not lists:member({Source, Module}, ReadySet)
            ],
            order_sources(
                Remaining,
                Internal,
                ReadyModules ++ [Module || {_Source, Module, _Transforms} <- Ready],
                lists:reverse(Ready) ++ Ordered
            )
    end.

compile_source(Source, Options, TransformModules) ->
    case compile:file(Source, Options) of
        {ok, Module} -> maybe_load_transform(Module, TransformModules, Options), Module;
        {ok, Module, _Warnings} -> maybe_load_transform(Module, TransformModules, Options), Module;
        Error -> erlang:error({compilation_failed, Source, Error})
    end.

maybe_load_transform(Module, TransformModules, Options) ->
    case lists:member(Module, TransformModules) of
        false -> ok;
        true ->
            {outdir, Ebin} = lists:keyfind(outdir, 1, Options),
            {module, Module} = code:load_abs(filename:join(Ebin, atom_to_list(Module))),
            ok
    end.

write_application(Config, Ebin, Modules) ->
    App = list_to_atom(maps:get(app, Config)),
    Version = maps:get(version, Config),
    Applications = lists:usort([kernel, stdlib] ++ [list_to_atom(Name) || Name <- maps:get(applications, Config)]),
    Properties0 = case maps:get(app_src, Config, none) of
        none -> [];
        Path ->
            {ok, [{application, App, Properties}]} = file:consult(Path),
            Properties
    end,
    Properties1 = lists:keystore(vsn, 1, Properties0, {vsn, Version}),
    Properties2 = lists:keystore(modules, 1, Properties1, {modules, Modules}),
    Properties3 = lists:keystore(applications, 1, Properties2, {applications, Applications}),
    file:write_file(
        filename:join(Ebin, atom_to_list(App) ++ ".app"),
        io_lib:format("~tp.~n", [{application, App, Properties3}])
    ).

stage_priv([], _Destination) -> ok;
stage_priv(Entries, Destination) ->
    stage_entries(Entries, Destination).

stage_entries([], _Destination) -> ok;
stage_entries(Entries, Destination) ->
    lists:foreach(
        fun({Source, Relative}) -> copy_entry(Source, filename:join(Destination, Relative)) end,
        Entries
    ).

copy_entry(Source, Destination) ->
    case file:read_link_info(Source) of
        {ok, #file_info{type = symlink}} ->
            {ok, Target} = file:read_link(Source),
            ok = ensure_parent(Destination),
            file:make_symlink(Target, Destination);
        {ok, #file_info{type = directory}} ->
            ok = ensure_directory(Destination),
            {ok, Children} = file:list_dir(Source),
            lists:foreach(
                fun(Child) -> copy_entry(filename:join(Source, Child), filename:join(Destination, Child)) end,
                Children
            );
        {ok, Info} ->
            ok = ensure_parent(Destination),
            {ok, _Bytes} = file:copy(Source, Destination),
            {ok, CopiedInfo} = file:read_file_info(Destination),
            file:write_file_info(Destination, CopiedInfo#file_info{mode = Info#file_info.mode});
        Error ->
            erlang:error({priv_copy_failed, Source, Destination, Error})
    end.

option(true, Value) -> [Value];
option(false, _Value) -> [].

write_fingerprint(Root, Destination) ->
    Entries = lists:sort(fingerprint_entries(Root, Root)),
    ok = ensure_parent(Destination),
    file:write_file(Destination, term_to_binary(Entries, [deterministic])).

fingerprint_entries(Path, Root) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory, mode = Mode}} ->
            {ok, Children} = file:list_dir(Path),
            DirectoryEntry = case Path =:= Root of
                true -> [];
                false -> [{relative_path(Path, Root), directory, Mode band 8#777}]
            end,
            DirectoryEntry ++ lists:flatmap(
                fun(Child) -> fingerprint_entries(filename:join(Path, Child), Root) end,
                Children
            );
        {ok, #file_info{type = symlink, mode = Mode}} ->
            {ok, Target} = file:read_link(Path),
            [{relative_path(Path, Root), symlink, Mode band 8#777, Target}];
        {ok, #file_info{type = regular, mode = Mode}} ->
            {ok, Content} = file:read_file(Path),
            [{
                relative_path(Path, Root),
                regular,
                Mode band 8#777,
                byte_size(Content),
                erlang:phash2(Content, 16#100000000),
                erlang:phash2({rules_elixir_mix, Content}, 16#100000000)
            }];
        {ok, _Info} ->
            [];
        Error ->
            erlang:error({fingerprint_failed, Path, Error})
    end.

relative_path(Path, Root) ->
    lists:nthtail(length(Root) + 1, Path).

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
