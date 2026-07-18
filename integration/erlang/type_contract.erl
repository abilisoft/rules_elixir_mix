-module(type_contract).
-export_type([contract_id/0]).

-type contract_id() :: non_neg_integer().
