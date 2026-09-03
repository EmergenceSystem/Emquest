-module(emquest_pop_hardening_tests).
-include_lib("eunit/include/eunit.hrl").

opts_include_hardening_test() ->
    Opts = emquest_pop:node_opts_for_test(),
    ?assertEqual(true, maps:get(reject_private_hosts, Opts)),
    ?assert(maps:get(max_peers_per_source, Opts) > 0),
    ?assert(is_list(maps:get(root_pubkeys, Opts))),
    ?assert(lists:all(fun(K) -> byte_size(K) =:= 32 end, maps:get(root_pubkeys, Opts))).
