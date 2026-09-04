-module(emquest_pop_ban_tests).
-include_lib("eunit/include/eunit.hrl").

ban_passthrough_exported_test() ->
    code:ensure_loaded(emquest_pop),
    ?assert(erlang:function_exported(emquest_pop, ban, 2)),
    ?assert(erlang:function_exported(emquest_pop, unban, 1)),
    ?assert(erlang:function_exported(emquest_pop, set_trust, 2)).
