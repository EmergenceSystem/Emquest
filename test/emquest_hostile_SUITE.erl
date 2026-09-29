%%% Hostile-node harness (Plan 5).
%%%
%%% Stands up an ENFORCED mesh context (require_signatures_v2 +
%%% require_signed_gossip on, relay_query_hubs=all) with an honest signing
%%% filter and ONE real em_pop_node whose /pop/gossip listener the adversary
%%% cases target. All state lives on ephemeral ports and /tmp dirs -- never
%%% prod config/ or priv/.
-module(emquest_hostile_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([honest_query_succeeds/1]).

all() -> [honest_query_succeeds].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    application:ensure_all_started(kvex),
    application:set_env(emquest, require_signatures_v2, true),
    application:set_env(em_filter, require_signed_gossip, true),
    application:set_env(emquest, relay_query_hubs, all),

    Uniq = integer_to_list(erlang:unique_integer([positive])),
    StoreDir = "/tmp/emq_hostile_" ++ Uniq,
    KeyDir = "/tmp/emq_hostile_key_" ++ Uniq,
    ok = filelib:ensure_dir(StoreDir ++ "/x"),
    catch em_pop_store:close(),
    %% dets tables die with the process that opened them, and CT runs
    %% init_per_suite in a short-lived process -- so a dedicated holder
    %% process owns the store for the whole suite.
    Holder = start_store_holder(StoreDir ++ "/s.dets"),

    %% Honest filter identity, TOFU-bound exactly as em_pop_node does on the
    %% first self-signed hello.
    {HPub, HPriv} = em_pop_crypto:keypair(),
    SignerId = em_pop_crypto:id_of(HPub),
    em_pop_store:put_pubkey(SignerId, HPub),

    %% One real node; its init auto-starts the /pop/gossip cowboy listener
    %% on Port (route opts are just #{node => NodePid}).
    Port = free_port(),
    Vec = em_filter_vec:from_capabilities([<<"search">>]),
    {ok, NodePid} = em_pop_node:start_link(#{port            => Port,
                                             vector          => Vec,
                                             gossip_interval => 0,
                                             node_key_dir    => KeyDir}),
    unlink(NodePid),
    [{honest, {HPub, HPriv, SignerId}},
     {node, NodePid},
     {gossip_port, Port},
     {store_holder, Holder},
     {store_dir, StoreDir},
     {key_dir, KeyDir} | Config].

end_per_suite(Config) ->
    NodePid = proplists:get_value(node, Config),
    catch gen_server:stop(NodePid),
    stop_store_holder(proplists:get_value(store_holder, Config)),
    [file:del_dir_r(proplists:get_value(K, Config)) || K <- [store_dir, key_dir]],
    application:unset_env(emquest, require_signatures_v2),
    application:unset_env(em_filter, require_signed_gossip),
    application:unset_env(emquest, relay_query_hubs),
    ok.

%% Positive control: under enforcement, a legit v2-signed response from a
%% TOFU-bound filter is ACCEPTED, so the adversary cases are not vacuous.
honest_query_succeeds(Config) ->
    {_HPub, HPriv, SignerId} = proplists:get_value(honest, Config),
    Items = [#{<<"url">> => <<"http://x/a">>, <<"title">> => <<"A">>}],
    Ts = erlang:system_time(millisecond),
    Sig = em_pop_crypto:sign(
            em_pop_crypto:canonical_response_v2(<<"alpha">>, Ts, Items), HPriv),
    RespMap = #{<<"results">>   => Items,
                <<"ts">>        => Ts,
                <<"signer_id">> => base64:encode(SignerId),
                <<"signature">> => base64:encode(Sig)},
    true = emquest_handler:response_ok(<<"alpha">>, RespMap, Items),
    ok.

start_store_holder(File) ->
    Parent = self(),
    Ref = make_ref(),
    Holder = spawn(fun() ->
        Parent ! {Ref, em_pop_store:open(File)},
        receive {stop, From} -> catch em_pop_store:close(), From ! {stopped, self()} end
    end),
    receive {Ref, {ok, _}} -> Holder
    after 5000 -> error(store_open_timeout) end.

stop_store_holder(Holder) ->
    Holder ! {stop, self()},
    receive {stopped, Holder} -> ok after 5000 -> ok end.

%% Pick a currently-free ephemeral TCP port.
free_port() ->
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, P} = inet:port(L),
    gen_tcp:close(L),
    P.
