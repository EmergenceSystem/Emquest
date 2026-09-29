-module(em_pop_node_identity_tests).
-include_lib("eunit/include/eunit.hrl").

-define(VEC, em_filter_vec:from_capabilities([<<"test">>])).

node_advertises_selfsig_test() ->
    Dir = "/tmp/emq_node_key_" ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, Pid} = em_pop_node:start_link(#{port => 0, vector => ?VEC,
                                         name => <<"emquest">>,
                                         gossip_interval => 0,
                                         node_key_dir => Dir}),
    try
        P = em_pop_node:state_payload_for_test(sys:get_state(Pid)),
        Pub = em_pop_crypto:pubkey(),
        Id = em_pop_crypto:id_of(Pub),
        ?assert(filelib:is_regular(filename:join(Dir, "node_ed25519.key"))),
        ?assertEqual(base64:encode(Pub), maps:get(<<"pubkey">>, P)),
        ?assertEqual(base64:encode(Id), maps:get(<<"id">>, P)),
        ?assertEqual(Id, em_pop_node:get_id(Pid)),
        ?assert(is_binary(maps:get(<<"sig">>, P))),
        ?assert(em_pop_crypto:verify_selfsig(#{id => Id, name => <<"emquest">>,
            pubkey => Pub, sig => base64:decode(maps:get(<<"sig">>, P))}))
    after
        unlink(Pid), exit(Pid, shutdown),
        os:cmd("rm -rf " ++ Dir)
    end.

node_id_stable_across_restart_test() ->
    Dir = "/tmp/emq_node_key_" ++ integer_to_list(erlang:unique_integer([positive])),
    Opts = #{port => 0, vector => ?VEC, name => <<"emquest">>,
             gossip_interval => 0, node_key_dir => Dir},
    {ok, P1} = em_pop_node:start_link(Opts),
    Id1 = em_pop_node:get_id(P1),
    unlink(P1), exit(P1, shutdown),
    timer:sleep(100),
    {ok, P2} = em_pop_node:start_link(Opts),
    try ?assertEqual(Id1, em_pop_node:get_id(P2))
    after unlink(P2), exit(P2, shutdown), os:cmd("rm -rf " ++ Dir)
    end.
