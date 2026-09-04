-module(emquest_relay_route_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([relay_fetch_verifies/1, relay_fetch_unreachable_hub_returns_error/1]).

all() ->
    [relay_fetch_verifies, relay_fetch_unreachable_hub_returns_error].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) -> ok.

%% A relay peer (query_port=null, relay_via set) is fetched via its hub's
%% POST /relay/query, and the signed {results, signer_id, signature}
%% response verifies -- items are returned, not dropped. Stands up a
%% local cowboy stub answering /relay/query with a response signed by a
%% keypair TOFU-bound in em_pop_store, then calls the real fetch
%% entrypoint (emquest_handler:fetch_via_relay/3) exactly as
%% dispatch_pop_worker/2 does for a query_port=null + relay_via peer.
relay_fetch_verifies(_Config) ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    SignerId = em_pop_crypto:id_of(Pub),
    catch em_pop_store:close(),
    Dir = "/tmp/emq_relay_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(Dir ++ "/x"),
    {ok, _} = em_pop_store:open(Dir ++ "/s.dets"),
    %% TOFU-bind the filter's pubkey, exactly as em_pop_node does the
    %% first time it sees a self-signed peer (Task 1.3's hello handshake).
    em_pop_store:put_pubkey(SignerId, Pub),

    Items = [#{<<"url">> => <<"http://example.com/a">>,
               <<"title">> => <<"A">>, <<"resume">> => <<"r">>}],
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_response(Items), Priv),
    %% Same shape em_disco_relay's HTTP handler round-trips from the
    %% filter's own WS "result" frame (Task 1.3/1.4) -- action/id plus the
    %% signed results/signer_id/signature that response_ok/2 verifies.
    RespMap = #{<<"action">> => <<"result">>,
                <<"results">> => Items,
                <<"signer_id">> => base64:encode(SignerId),
                <<"signature">> => base64:encode(Sig)},

    Dispatch = cowboy_router:compile([
        {'_', [{"/relay/query", mock_relay_hub_handler, #{resp => RespMap}}]}
    ]),
    {ok, _} = cowboy:start_clear(mock_relay_hub_listener,
                                  [{port, 19610}],
                                  #{env => #{dispatch => Dispatch}}),
    application:set_env(emquest, relay_hub_http_port, 19610),

    PeerId = crypto:strong_rand_bytes(16),
    HubPeerMap = #{host => <<"localhost">>},
    Result = emquest_handler:fetch_via_relay(PeerId, HubPeerMap, <<"test query">>),

    cowboy:stop_listener(mock_relay_hub_listener),
    application:unset_env(emquest, relay_hub_http_port),
    em_pop_store:close(), file:delete(Dir ++ "/s.dets"),

    {ok, [Item]} = Result,
    <<"http://example.com/a">> = maps:get(<<"url">>, Item).

%% An unresolvable/unreachable relay hub is a plain peer error -- not a
%% crash, and not silently treated as an empty success.
relay_fetch_unreachable_hub_returns_error(_Config) ->
    application:set_env(emquest, relay_hub_http_port, 1),
    HubPeerMap = #{host => <<"localhost">>},
    Result = emquest_handler:fetch_via_relay(
                 crypto:strong_rand_bytes(16), HubPeerMap, <<"q">>),
    application:unset_env(emquest, relay_hub_http_port),
    {error, _} = Result.
