-module(em_pop_node_hardening_tests).
-include_lib("eunit/include/eunit.hrl").

host_blocked_test() ->
    ?assertEqual(true,  emquest_safeurl:host_blocked(<<"127.0.0.1">>)),
    ?assertEqual(false, emquest_safeurl:host_blocked(<<"example.com">>)).

host_guard_rejects_private_from_nonroot_test() ->
    S0 = em_pop_node:test_state(#{reject_private_hosts => true, root_pubkeys => []}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"10.0.0.9">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"evil.example">>, pubkey => <<2:256>>}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assertNot(em_pop_node:has_peer(S1, <<1:128>>)).

host_guard_allows_private_from_root_test() ->
    Root = <<7:256>>,
    S0 = em_pop_node:test_state(#{reject_private_hosts => true, root_pubkeys => [Root]}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"localhost">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"root.example">>, pubkey => Root}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assert(em_pop_node:has_peer(S1, <<1:128>>)).

host_guard_allows_public_from_nonroot_test() ->
    S0 = em_pop_node:test_state(#{reject_private_hosts => true, root_pubkeys => []}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"93.184.216.34">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"peer.example">>, pubkey => <<2:256>>}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assert(em_pop_node:has_peer(S1, <<1:128>>)).

host_guard_off_keeps_private_test() ->
    S0 = em_pop_node:test_state(#{reject_private_hosts => false, root_pubkeys => []}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"10.0.0.9">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"evil.example">>, pubkey => <<2:256>>}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assert(em_pop_node:has_peer(S1, <<1:128>>)).

sybil_caps_nonroot_source_test() ->
    S0 = em_pop_node:test_state(#{max_peers_per_source => 2, root_pubkeys => []}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"h.example">>, pubkey => <<2:256>>}),
    Ps = [em_pop_node:test_peer(#{id => <<N:128>>, host => <<"93.184.216.34">>,
             query_port => 9200+N, vector => em_pop_node:test_vector(S0)}) || N <- [1,2,3,4]],
    S1 = em_pop_node:merge_peers_from(Ps, Src, S0),
    Kept = length([1 || N <- [1,2,3,4], em_pop_node:has_peer(S1, <<N:128>>)]),
    ?assertEqual(2, Kept).

sybil_root_source_unlimited_test() ->
    Root = <<7:256>>,
    S0 = em_pop_node:test_state(#{max_peers_per_source => 2, root_pubkeys => [Root]}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"r.example">>, pubkey => Root}),
    Ps = [em_pop_node:test_peer(#{id => <<N:128>>, host => <<"93.184.216.34">>,
             query_port => 9200+N, vector => em_pop_node:test_vector(S0)}) || N <- [1,2,3,4]],
    S1 = em_pop_node:merge_peers_from(Ps, Src, S0),
    ?assertEqual(4, length([1 || N <- [1,2,3,4], em_pop_node:has_peer(S1, <<N:128>>)])).

canonical_ban_stable_test() ->
    B = em_pop_crypto:canonical_ban(<<1:128>>, 1234567890),
    ?assert(is_binary(B)),
    ?assertEqual(B, em_pop_crypto:canonical_ban(<<1:128>>, 1234567890)).

ban_sign_verify_roundtrip_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Rec = em_pop_crypto:canonical_ban(<<1:128>>, 1234567890),
    Sig = em_pop_crypto:sign(Rec, Priv),
    ?assert(em_pop_crypto:verify(Rec, Sig, Pub)),
    ?assertNot(em_pop_crypto:verify(em_pop_crypto:canonical_ban(<<1:128>>, 9), Sig, Pub)).

apply_authority_signed_ban_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    S1 = em_pop_node:test_add_peer(S0, <<1:128>>, <<"93.184.216.34">>),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, Ts), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
            <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Pub)},
    S2 = em_pop_node:apply_bans_from([Ban], S1),
    ?assert(em_pop_node:is_banned_st(S2, <<1:128>>)),
    ?assertNot(em_pop_node:has_peer(S2, <<1:128>>)).

ignore_forged_ban_test() ->
    {_Pub, Priv} = em_pop_crypto:keypair(),
    {Auth, _} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Auth]}),
    S1 = em_pop_node:test_add_peer(S0, <<1:128>>, <<"93.184.216.34">>),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, Ts), Priv), %% wrong key
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
            <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Auth)},
    S2 = em_pop_node:apply_bans_from([Ban], S1),
    ?assertNot(em_pop_node:is_banned_st(S2, <<1:128>>)),
    ?assert(em_pop_node:has_peer(S2, <<1:128>>)).

emit_bans_in_payload_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, Ts), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
            <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Pub)},
    S2 = em_pop_node:apply_bans_from([Ban], S0),
    Payload = em_pop_node:state_payload_for_test(S2),
    Bans = maps:get(<<"bans">>, Payload, []),
    ?assertEqual(1, length(Bans)).

%%--------------------------------------------------------------------
%% Signed un-ban (tombstone) tests -- mirror the ban tests above.
%%--------------------------------------------------------------------

canonical_unban_stable_test() ->
    B = em_pop_crypto:canonical_unban(<<1:128>>, 1234567890),
    ?assert(is_binary(B)),
    ?assertEqual(B, em_pop_crypto:canonical_unban(<<1:128>>, 1234567890)).

canonical_unban_differs_from_ban_test() ->
    %% Domain byte (0 vs 1) must make the two canonical forms differ, so a
    %% ban signature can never be replayed as an un-ban signature.
    ?assertNotEqual(em_pop_crypto:canonical_ban(<<1:128>>, 100),
                     em_pop_crypto:canonical_unban(<<1:128>>, 100)).

unban_sign_verify_roundtrip_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Rec = em_pop_crypto:canonical_unban(<<1:128>>, 1234567890),
    Sig = em_pop_crypto:sign(Rec, Priv),
    ?assert(em_pop_crypto:verify(Rec, Sig, Pub)),
    ?assertNot(em_pop_crypto:verify(em_pop_crypto:canonical_unban(<<1:128>>, 9), Sig, Pub)),
    %% A ban signature over the same id/ts must not verify as an un-ban.
    BanSig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, 1234567890), Priv),
    ?assertNot(em_pop_crypto:verify(Rec, BanSig, Pub)).

%% (a) apply a signed ban (ts=100) -> is_banned true.
signed_ban_then_no_unban_is_banned_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    BanSig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, 100), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 100,
            <<"sig">> => base64:encode(BanSig), <<"signer">> => base64:encode(Pub)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    ?assert(em_pop_node:is_banned_st(S1, <<1:128>>)).

%% (b) apply a signed un-ban (same id, ts=200) -> is_banned false.
signed_unban_newer_ts_clears_ban_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    BanSig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, 100), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 100,
            <<"sig">> => base64:encode(BanSig), <<"signer">> => base64:encode(Pub)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    ?assert(em_pop_node:is_banned_st(S1, <<1:128>>)),
    UnbanSig = em_pop_crypto:sign(em_pop_crypto:canonical_unban(<<1:128>>, 200), Priv),
    Unban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 200,
              <<"sig">> => base64:encode(UnbanSig), <<"signer">> => base64:encode(Pub)},
    S2 = em_pop_node:apply_unbans_from([Unban], S1),
    ?assertNot(em_pop_node:is_banned_st(S2, <<1:128>>)).

%% (c) an un-ban with ts=50 (older than the ban's ts=100) -> still banned.
signed_unban_older_ts_does_not_clear_ban_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    BanSig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, 100), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 100,
            <<"sig">> => base64:encode(BanSig), <<"signer">> => base64:encode(Pub)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    UnbanSig = em_pop_crypto:sign(em_pop_crypto:canonical_unban(<<1:128>>, 50), Priv),
    Unban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 50,
              <<"sig">> => base64:encode(UnbanSig), <<"signer">> => base64:encode(Pub)},
    S2 = em_pop_node:apply_unbans_from([Unban], S1),
    ?assert(em_pop_node:is_banned_st(S2, <<1:128>>)).

%% (d) re-applying the old ban (ts=100) after the ts=200 un-ban -> still
%% NOT banned (newest-ts-wins; the still-propagating ban record must not
%% resurrect a lifted ban).
old_ban_replay_after_newer_unban_stays_cleared_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    BanSig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, 100), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 100,
            <<"sig">> => base64:encode(BanSig), <<"signer">> => base64:encode(Pub)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    UnbanSig = em_pop_crypto:sign(em_pop_crypto:canonical_unban(<<1:128>>, 200), Priv),
    Unban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 200,
              <<"sig">> => base64:encode(UnbanSig), <<"signer">> => base64:encode(Pub)},
    S2 = em_pop_node:apply_unbans_from([Unban], S1),
    ?assertNot(em_pop_node:is_banned_st(S2, <<1:128>>)),
    %% Replay the old (ts=100) ban record -- as if the still-propagating
    %% gossip record re-taught it to this node.
    S3 = em_pop_node:apply_bans_from([Ban], S2),
    ?assertNot(em_pop_node:is_banned_st(S3, <<1:128>>)).

ignore_forged_unban_test() ->
    {_Pub, Priv} = em_pop_crypto:keypair(),
    {Auth, AuthPriv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Auth]}),
    BanSig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, 100), AuthPriv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 100,
            <<"sig">> => base64:encode(BanSig), <<"signer">> => base64:encode(Auth)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    ?assert(em_pop_node:is_banned_st(S1, <<1:128>>)),
    Ts = erlang:system_time(second),
    ForgedSig = em_pop_crypto:sign(em_pop_crypto:canonical_unban(<<1:128>>, Ts), Priv), %% wrong key
    Unban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
              <<"sig">> => base64:encode(ForgedSig), <<"signer">> => base64:encode(Auth)},
    S2 = em_pop_node:apply_unbans_from([Unban], S1),
    %% Forged signer/key mismatch -- un-ban rejected, ban still stands.
    ?assert(em_pop_node:is_banned_st(S2, <<1:128>>)).

emit_unbans_in_payload_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_unban(<<1:128>>, Ts), Priv),
    Unban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
              <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Pub)},
    S2 = em_pop_node:apply_unbans_from([Unban], S0),
    Payload = em_pop_node:state_payload_for_test(S2),
    Unbans = maps:get(<<"unbans">>, Payload, []),
    ?assertEqual(1, length(Unbans)).

unban_clears_merge_peers_ban_exclusion_test() ->
    %% A peer whose ban was cleared by a newer un-ban must be re-admittable
    %% through merge_peers (not just is_banned_st) -- exercises the guard
    %% fix directly, mirroring shared_banned_not_readmitted_test's shape.
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    BanSig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, 100), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 100,
            <<"sig">> => base64:encode(BanSig), <<"signer">> => base64:encode(Pub)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"h.example">>, pubkey => <<2:256>>}),
    P = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"93.184.216.34">>,
                                query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    %% Still banned -> refused.
    S2 = em_pop_node:merge_peers_from([P], Src, S1),
    ?assertNot(em_pop_node:has_peer(S2, <<1:128>>)),
    %% Clear the ban with a newer un-ban -> now re-admittable.
    UnbanSig = em_pop_crypto:sign(em_pop_crypto:canonical_unban(<<1:128>>, 200), Priv),
    Unban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => 200,
              <<"sig">> => base64:encode(UnbanSig), <<"signer">> => base64:encode(Pub)},
    S3 = em_pop_node:apply_unbans_from([Unban], S1),
    S4 = em_pop_node:merge_peers_from([P], Src, S3),
    ?assert(em_pop_node:has_peer(S4, <<1:128>>)).
