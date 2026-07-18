-module(type_consumer).
-export([increment/1]).

-spec increment(type_contract:contract_id()) -> type_contract:contract_id().
increment(Value) ->
    Value + 1.
