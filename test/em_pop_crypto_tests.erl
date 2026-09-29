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
    %% host/port are NOT signed (hubs rewrite them) — changing host stays valid.
    ?assert(em_pop_crypto:verify_selfsig(Ident#{host => <<"rewritten">>, pubkey => Pub, sig => Sig})),
    %% name IS signed — tampering it breaks verification.
    ?assertNot(em_pop_crypto:verify_selfsig(Ident#{name => <<"evil">>, pubkey => Pub, sig => Sig})),
    %% id must match id_of(pubkey).
    ?assertNot(em_pop_crypto:verify_selfsig(Ident#{id => <<0:128>>, pubkey => Pub, sig => Sig})).

%% Byte-parity fixture: em_filter_src's em_pop_crypto:canonical_response_v2/3
%% produced exactly these bytes. If this fails, the two copies have drifted and
%% v2 signatures will no longer verify across nodes.
canonical_response_v2_parity_fixture_test() ->
    Items = [#{<<"url">> => <<"u">>, <<"title">> => <<"t">>, <<"resume">> => <<"r">>}],
    Bytes = em_pop_crypto:canonical_response_v2(<<"québec"/utf8>>, 1700000000000, Items),
    ?assertEqual([113,117,195,169,98,101,99,0,49,55,48,48,48,48,48,48,48,48,48,48,48,0,117,0,116,0,114,10],
                 binary_to_list(Bytes)).

canonical_gossip_auth_bytes_test() ->
    BodyHash = crypto:hash(sha256, <<"{}">>),
    Expect = <<"id0", 0, "1700000000000", 0, BodyHash/binary>>,
    ?assertEqual(Expect, em_pop_crypto:canonical_gossip_auth(<<"id0">>, 1700000000000, BodyHash)).

canonical_gossip_auth_parity_fixture_test() ->
    Bytes = em_pop_crypto:canonical_gossip_auth(<<"québec"/utf8>>, 1700000000000,
                                                crypto:hash(sha256, <<"{}">>)),
    ?assertEqual([113,117,195,169,98,101,99,0,49,55,48,48,48,48,48,48,48,48,48,48,48,0,68,19,111,163,85,179,103,138,17,70,173,22,247,232,100,158,148,251,79,194,31,231,126,131,16,192,96,246,28,170,255,138],
                 binary_to_list(Bytes)).

emquest_keypair_load_or_create_test() ->
    Dir = "/tmp/emquest_key_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    {Pub, _Priv} = em_pop_crypto:load_or_create(Dir),
    ?assertEqual(16, byte_size(em_pop_crypto:id_of(Pub))),
    ?assertEqual(Pub, em_pop_crypto:pubkey()),
    {Pub2, _} = em_pop_crypto:load_or_create(Dir),
    ?assertEqual(Pub, Pub2).

pin_url_ipv6_with_port_test() ->
    ?assertEqual({"http://[2606:2800::1]:80/x", "[2606:2800::1]:80"},
                 emquest_safeurl:pin_url(<<"http://[2606:2800::1]:80/x">>,
                                         {9734,10240,0,0,0,0,0,1})).

pin_url_ipv6_no_port_bracketed_host_header_test() ->
    ?assertEqual({"https://[2606:2800::1]/x", "[2606:2800::1]"},
                 emquest_safeurl:pin_url(<<"https://[2606:2800::1]/x">>,
                                         {9734,10240,0,0,0,0,0,1})).

pin_url_ipv6_pin_from_name_test() ->
    ?assertEqual({"http://[2606:2800::1]/x", "example.com"},
                 emquest_safeurl:pin_url(<<"http://example.com/x">>,
                                         {9734,10240,0,0,0,0,0,1})).

load_or_create_perms_and_corrupt_test() ->
    Dir = "/tmp/emq_crypto_lc_" ++ integer_to_list(erlang:unique_integer([positive])),
    File = filename:join(Dir, "node_ed25519.key"),
    {Pub, Priv} = em_pop_crypto:load_or_create(Dir),
    {ok, Info} = file:read_file_info(File),
    ?assertEqual(8#600, element(8, Info) band 8#777),
    ?assertEqual({Pub, Priv}, em_pop_crypto:load_or_create(Dir)),
    ok = file:write_file(File, <<"short">>),
    ?assertError({bad_node_key, File, 5}, em_pop_crypto:load_or_create(Dir)),
    ?assertEqual(<<"short">>, element(2, file:read_file(File))),
    os:cmd("rm -rf " ++ Dir).
