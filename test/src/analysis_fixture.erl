-module(analysis_fixture).
-export([value/0]).

-include_lib("eunit/include/eunit.hrl").

value() -> ok.

value_test() ->
    ?assertEqual(ok, value()).
