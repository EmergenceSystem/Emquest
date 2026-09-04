-module(em_pop_node_payload_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([relay_payload_roundtrip/1, relay_via_and_query_port_carried_on_reoutput/1]).

all() ->
    [relay_payload_roundtrip, relay_via_and_query_port_carried_on_reoutput].

init_per_suite(Config) ->
    application:ensure_all_started(kvex),
    Config.

end_per_suite(_Config) -> ok.

%% A gossip payload carrying relay_via + null query_port + capabilities
%% round-trips through payload_to_peer/1: query_port decodes to undefined,
%% relay_via decodes back to raw bytes, and the vector is the local
%% hub-authoritative recompute from capabilities (not the wire vector).
relay_payload_roundtrip(_Config) ->
    {Pub, _Priv} = em_pop_crypto:keypair(),
    Id = em_pop_crypto:id_of(Pub),
    BogusVec = crypto:strong_rand_bytes(256),
    Payload = #{<<"id">> => base64:encode(Id), <<"name">> => <<"r">>,
        <<"host">> => <<"disco.example">>, <<"port">> => 9080,
        <<"pubkey">> => base64:encode(Pub),
        <<"query_port">> => null,
        <<"relay_via">> => base64:encode(<<"hub">>),
        <<"vector">> => base64:encode(BogusVec),
        <<"capabilities">> => [<<"search">>]},
    Peer = em_pop_node:payload_to_peer(Payload),
    undefined = em_pop_node:peer_query_port(Peer),
    <<"hub">> = em_pop_node:peer_relay_via(Peer),
    ExpectedVec = em_filter_vec:from_capabilities([<<"search">>]),
    ExpectedVec = em_pop_node:peer_vector(Peer),
    ok.

%% A peer decoded from a relay payload (relay_via + null query_port) is
%% re-serialised via peer_to_payload/state_to_payload with the same
%% relay_via and null query_port preserved -- the field survives a full
%% decode/re-encode cycle through this node, not just the initial decode.
relay_via_and_query_port_carried_on_reoutput(_Config) ->
    Vec = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19901,
                                          vector          => Vec,
                                          gossip_interval => 0}),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, _Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>           => RemoteId,
        <<"host">>         => <<"127.0.0.1">>,
        <<"port">>         => 9997,
        <<"query_port">>   => null,
        <<"relay_via">>    => base64:encode(<<"some-hub-id">>),
        <<"vector">>       => base64:encode(Vec),
        <<"capabilities">> => [<<"web">>],
        <<"peers">>        => []
    }),
    RemoteId2 = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, ReGossipPayload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId2,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9996,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    AdvPeers = maps:get(<<"peers">>, ReGossipPayload),
    RemoteIdB64 = RemoteId,
    [AdvPeer] = [X || X <- AdvPeers, maps:get(<<"id">>, X) =:= RemoteIdB64],
    null = maps:get(<<"query_port">>, AdvPeer),
    <<"some-hub-id">> = base64:decode(maps:get(<<"relay_via">>, AdvPeer)),
    ExpectedVec = em_filter_vec:from_capabilities([<<"web">>]),
    ExpectedVecB64 = base64:encode(ExpectedVec),
    ExpectedVecB64 = maps:get(<<"vector">>, AdvPeer),
    gen_server:stop(Pid),
    ok.
