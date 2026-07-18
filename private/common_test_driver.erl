%% Shell-free Common Test runner with declared configuration and SUITE_data.
-module(common_test_driver).
-export([main/1]).

-include_lib("kernel/include/file.hrl").

main([ConfigPath]) ->
    {ok, [Config]} = file:consult(ConfigPath),
    {ok, _} = application:ensure_all_started(common_test),
    Root = filename:join(os:getenv("TEST_TMPDIR", "."), "common_test_suites"),
    ok = remove(Root),
    ok = ensure_directory(Root),
    Suites = maps:get(suites, Config),
    lists:foreach(fun(Suite) -> stage_suite(Suite, Root) end, Suites),
    lists:foreach(
        fun({Source, Suite, Relative}) ->
            copy_entry(filename:absname(Source), filename:join([Root, atom_to_list(Suite) ++ "_data", Relative]))
        end,
        maps:get(suite_data, Config, [])
    ),
    Log = filename:join(os:getenv("TEST_UNDECLARED_OUTPUTS_DIR", os:getenv("TEST_TMPDIR", ".")), "common_test"),
    ok = ensure_directory(Log),
    Options0 = [
        {dir, [Root]},
        {suite, Suites},
        {auto_compile, false},
        {logdir, Log},
        {verbosity, maps:get(verbosity, Config)}
    ],
    Options1 = add_option(config, [filename:absname(Path) || Path <- maps:get(config_files, Config, [])], Options0),
    Options2 = add_option(group, maps:get(groups, Config, []), Options1),
    Options3 = add_option(testcase, maps:get(cases, Config, []), Options2),
    Options4 = add_option(ct_hooks, maps:get(hooks, Config, []), Options3),
    Options = case maps:get(repeat, Config, 1) of
        1 -> Options4;
        Count -> [{repeat, Count} | Options4]
    end,
    Result = ct:run_test(Options),
    case successful(Result) of
        true -> ok;
        false -> erlang:error({common_test_failed, Result})
    end.

successful({_Ok, 0, {_UserSkipped, _AutoSkipped}}) -> true;
successful(Results) when is_list(Results) -> lists:all(fun successful/1, Results);
successful(_Result) -> false.

add_option(_Name, [], Options) -> Options;
add_option(Name, Value, Options) -> [{Name, Value} | Options].

stage_suite(Suite, Root) ->
    case code:which(Suite) of
        non_existing -> erlang:error({common_test_suite_not_found, Suite});
        Beam -> copy_entry(Beam, filename:join(Root, atom_to_list(Suite) ++ ".beam"))
    end.

copy_entry(Source, Destination) ->
    case file:read_link_info(Source) of
        {ok, #file_info{type = symlink}} ->
            {ok, Target} = file:read_link(Source),
            Resolved = case filename:pathtype(Target) of
                absolute -> Target;
                _ -> filename:join(filename:dirname(Source), Target)
            end,
            copy_entry(Resolved, Destination);
        {ok, #file_info{type = directory}} ->
            ok = ensure_directory(Destination),
            {ok, Children} = file:list_dir(Source),
            lists:foreach(
                fun(Child) -> copy_entry(filename:join(Source, Child), filename:join(Destination, Child)) end,
                lists:sort(Children)
            );
        {ok, #file_info{type = regular}} ->
            ok = filelib:ensure_dir(Destination),
            {ok, _} = file:copy(Source, Destination),
            ok;
        Error -> erlang:error({common_test_data_copy_failed, Source, Destination, Error})
    end.

ensure_directory(Path) ->
    filelib:ensure_dir(filename:join(Path, ".keep")).

remove(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> file:del_dir_r(Path);
        {ok, _} -> file:delete(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.
