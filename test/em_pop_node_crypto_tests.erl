-module(em_pop_node_crypto_tests).
-include_lib("eunit/include/eunit.hrl").

%% accept_peer is exercised through payload round-trips would need a live node;
%% instead test the decision surface via a tiny exported test hook. Export
%% accept_peer/1 from em_pop_node for testability.

setup() ->
    Dir  = "/tmp/em_pop_node_crypto_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok   = filelib:ensure_dir(Dir ++ "/x"),
    File = Dir ++ "/s.dets",
    {ok, _} = em_pop_store:open(File),
    File.
cleanup(File) -> catch em_pop_store:close(), catch file:delete(File), ok.

signed_peer_binds_and_accepts_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        {Pub, Priv} = em_pop_crypto:keypair(),
        Id  = em_pop_crypto:id_of(Pub),
        Ident = #{id => Id, host => <<"h">>, port => 9100, query_port => 9101, name => <<"n">>},
        Sig = em_pop_crypto:sign(em_pop_crypto:canonical_identity(Ident), Priv),
        P = em_pop_node:test_peer(Id, <<"h">>, 9100, 9101, <<"n">>, Pub, Sig),
        [?_assertEqual(true, em_pop_node:accept_peer(P))]
    end}.

unsigned_peer_accepted_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        P = em_pop_node:test_peer(<<0:128>>, <<"h">>, 9100, 9101, <<"n">>, undefined, undefined),
        [?_assertEqual(true, em_pop_node:accept_peer(P))]
    end}.

bad_sig_rejected_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        {Pub, _} = em_pop_crypto:keypair(),
        Id = em_pop_crypto:id_of(Pub),
        P = em_pop_node:test_peer(Id, <<"h">>, 9100, 9101, <<"n">>, Pub, <<0:512>>),
        [?_assertEqual(false, em_pop_node:accept_peer(P))]
    end}.

id_takeover_rejected_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        {Pub1, Priv1} = em_pop_crypto:keypair(),
        Id = em_pop_crypto:id_of(Pub1),
        I1 = #{id => Id, host => <<"h">>, port => 9100, query_port => 9101, name => <<"n">>},
        S1 = em_pop_crypto:sign(em_pop_crypto:canonical_identity(I1), Priv1),
        P1 = em_pop_node:test_peer(Id, <<"h">>, 9100, 9101, <<"n">>, Pub1, S1),
        true = em_pop_node:accept_peer(P1),         %% binds Id -> Pub1
        %% attacker: different key, claims the SAME id, signs with its own key over the same id
        {Pub2, Priv2} = em_pop_crypto:keypair(),
        I2 = #{id => Id, host => <<"h">>, port => 9100, query_port => 9101, name => <<"n">>},
        S2 = em_pop_crypto:sign(em_pop_crypto:canonical_identity(I2), Priv2),
        P2 = em_pop_node:test_peer(Id, <<"h">>, 9100, 9101, <<"n">>, Pub2, S2),
        %% verify_selfsig FAILS anyway because id =/= id_of(Pub2); belt-and-braces the bind conflict
        [?_assertEqual(false, em_pop_node:accept_peer(P2))]
    end}.
