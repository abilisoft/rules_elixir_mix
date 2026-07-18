-module(analysis_fixture_SUITE).
-export([all/0, value/1]).

all() ->
    [value].

value(_Config) ->
    ok = analysis_fixture:value(),
    ok.
