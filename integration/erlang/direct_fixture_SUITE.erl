-module(direct_fixture_SUITE).
-export([all/0, groups/0, value/1]).

all() ->
    [{group, values}].

groups() ->
    [{values, [], [value]}].

value(Config) ->
    ok = direct_fixture:value(),
    configured = ct:get_config(expected_config),
    DataDir = proplists:get_value(data_dir, Config),
    {ok, <<"declared suite data\n">>} = file:read_file(filename:join(DataDir, "payload.txt")),
    ok.
