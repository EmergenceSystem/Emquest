-module(em_pop_crypto_tests).
-include_lib("eunit/include/eunit.hrl").

sign_verify_roundtrip_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Msg = <<"hello world">>,
    Sig = em_pop_crypto:sign(Msg, Priv),
    ?assert(em_pop_crypto:verify(Msg, Sig, Pub)),
    ?assertNot(em_pop_crypto:verify(<<"tampered">>, Sig, Pub)).

verify_wrong_key_fails_test() ->
    {_Pub1, Priv1} = em_pop_crypto:keypair(),
    {Pub2, _}      = em_pop_crypto:keypair(),
    Sig = em_pop_crypto:sign(<<"m">>, Priv1),
    ?assertNot(em_pop_crypto:verify(<<"m">>, Sig, Pub2)).

id_of_is_16_bytes_and_deterministic_test() ->
    {Pub, _} = em_pop_crypto:keypair(),
    Id = em_pop_crypto:id_of(Pub),
    ?assertEqual(16, byte_size(Id)),
    ?assertEqual(Id, em_pop_crypto:id_of(Pub)).

canonical_identity_stable_test() ->
    M = #{id => <<1,2,3>>, host => <<"h">>, port => 9100,
          query_port => 9101, name => <<"n">>},
    ?assertEqual(em_pop_crypto:canonical_identity(M),
                 em_pop_crypto:canonical_identity(M)),
    ?assert(is_binary(em_pop_crypto:canonical_identity(M))).

verify_selfsig_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Id = em_pop_crypto:id_of(Pub),
    Ident = #{id => Id, host => <<"h">>, port => 9100,
              query_port => 9101, name => <<"n">>},
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_identity(Ident), Priv),
    ?assert(em_pop_crypto:verify_selfsig(Ident#{pubkey => Pub, sig => Sig})),
    ?assertNot(em_pop_crypto:verify_selfsig(Ident#{host => <<"evil">>, pubkey => Pub, sig => Sig})),
    ?assertNot(em_pop_crypto:verify_selfsig(Ident#{id => <<0:128>>, pubkey => Pub, sig => Sig})).
