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
-export([honest_query_succeeds/1, replay_query_mismatch_dropped/1,
         replay_stale_ts_dropped/1, banned_signer_dropped/1,
         ssrf_private_ip_blocked/1, ssrf_url_pinned_to_screened_ip/1,
         trust_not_on_the_wire/1]).

%% banned_signer_dropped bans (and finally unbans) the honest signer, so it
%% runs after every case that needs the signer to be in good standing.
all() -> [honest_query_succeeds,
          replay_query_mismatch_dropped, replay_stale_ts_dropped,
          ssrf_private_ip_blocked, ssrf_url_pinned_to_screened_ip,
          trust_not_on_the_wire,
          banned_signer_dropped].

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
    StoreFile = StoreDir ++ "/s.dets",
    Holder = start_store_holder(StoreFile),

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
     {store_file, StoreFile},
     {key_dir, KeyDir} | Config].

end_per_suite(Config) ->
    NodePid = proplists:get_value(node, Config),
    catch gen_server:stop(NodePid),
    stop_pop(Config),
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

%% Build a v2 response signed by the honest filter for Query at Ts.
signed_resp(Config, Query, Ts, Items) ->
    {_HPub, HPriv, SignerId} = proplists:get_value(honest, Config),
    Sig = em_pop_crypto:sign(
            em_pop_crypto:canonical_response_v2(Query, Ts, Items), HPriv),
    #{<<"results">>   => Items,
      <<"ts">>        => Ts,
      <<"signer_id">> => base64:encode(SignerId),
      <<"signature">> => base64:encode(Sig)}.

items() -> [#{<<"url">> => <<"http://x/a">>, <<"title">> => <<"A">>}].

%% ---- Case A: replay ------------------------------------------------------

%% A response signed for <<"alpha">> replayed as the answer to <<"beta">> is
%% dropped (the signature covers the query); the exact-match fresh response
%% is still accepted, so the drop is not a symptom of a broken fixture.
replay_query_mismatch_dropped(Config) ->
    Items = items(),
    Resp = signed_resp(Config, <<"alpha">>, erlang:system_time(millisecond), Items),
    true  = emquest_handler:response_ok(<<"alpha">>, Resp, Items),
    false = emquest_handler:response_ok(<<"beta">>, Resp, Items),
    ok.

%% A correctly-signed response that is an hour old falls outside the
%% freshness window and is dropped.
replay_stale_ts_dropped(Config) ->
    Items = items(),
    Fresh = erlang:system_time(millisecond),
    Stale = signed_resp(Config, <<"alpha">>, Fresh - 3600000, Items),
    false = emquest_handler:response_ok(<<"alpha">>, Stale, Items),
    FreshResp = signed_resp(Config, <<"alpha">>, Fresh, Items),
    true  = emquest_handler:response_ok(<<"alpha">>, FreshResp, Items),
    ok.

%% ---- Case B: ban evasion -------------------------------------------------

%% Once the signer is banned in the real emquest_pop (backed by a real
%% em_pop_node), its correctly-signed fresh v2 response is still dropped.
banned_signer_dropped(Config) ->
    {_HPub, _HPriv, SignerId} = proplists:get_value(honest, Config),
    Items = items(),
    Resp = signed_resp(Config, <<"alpha">>, erlang:system_time(millisecond), Items),
    %% Control: before the ban the same response is accepted.
    Config2 = start_pop(Config),
    try
        false = emquest_pop:is_banned(SignerId),
        true  = emquest_handler:response_ok(<<"alpha">>, Resp, Items),
        ok = emquest_pop:ban(SignerId, <<"test">>),
        true  = emquest_pop:is_banned(SignerId),
        false = emquest_handler:response_ok(<<"alpha">>, Resp, Items)
    after
        catch emquest_pop:unban(SignerId),
        stop_pop(Config2)
    end,
    ok.

%% Start the real emquest_pop gen_server (unlinked) on an ephemeral gossip
%% port, no seeds, sharing the suite'"'"'s /tmp dets store.
start_pop(Config) ->
    {ok, Pid} = gen_server:start({local, emquest_pop}, emquest_pop,
                                 #{pop_port   => free_port(),
                                   seeds      => [],
                                   state_file => proplists:get_value(store_file, Config)},
                                 []),
    [{pop, Pid} | Config].

stop_pop(_Config) ->
    case whereis(emquest_pop) of
        undefined -> ok;
        Pid ->
            #{node := Node} = sys:get_state(Pid),
            catch gen_server:stop(Pid),
            catch gen_server:stop(Node),
            ok
    end.

%% ---- Case E: SSRF / DNS-rebind -------------------------------------------

ssrf_private_ip_blocked(_Config) ->
    {error, _} = emquest_safeurl:check(<<"http://169.254.169.254/latest/meta-data">>),
    {error, _} = emquest_safeurl:check(<<"http://127.0.0.1:80/x">>),
    {error, _} = emquest_safeurl:check(<<"http://10.0.0.5/">>),
    {error, bad_scheme} = emquest_safeurl:check(<<"file:///etc/passwd">>),
    %% Control: a public address literal passes.
    ok = emquest_safeurl:check(<<"http://93.184.216.34/">>),
    ok.

%% The connection goes to the screened IP; the original name only travels
%% in the Host header, so a second (rebinding) DNS lookup cannot redirect it.
ssrf_url_pinned_to_screened_ip(_Config) ->
    {"http://93.184.216.34:9201/a", "example.com:9201"} =
        emquest_safeurl:pin_url(<<"http://example.com:9201/a">>, {93,184,216,34}),
    ok.

%% ---- Case F: trust not on the wire ---------------------------------------

%% Neither our own gossip payload nor any embedded peer map carries a
%% locally-derived trust score.
trust_not_on_the_wire(Config) ->
    NodePid = proplists:get_value(node, Config),
    Vec = em_filter_vec:from_capabilities([<<"search">>]),
    {ok, _} = em_pop_node:handle_gossip(NodePid, #{
        <<"id">>           => base64:encode(crypto:strong_rand_bytes(16)),
        <<"host">>         => <<"127.0.0.1">>,
        <<"port">>         => 9997,
        <<"query_port">>   => null,
        <<"vector">>       => base64:encode(Vec),
        <<"capabilities">> => [<<"web">>],
        <<"peers">>        => []}),
    Payload = em_pop_node:state_payload_for_test(sys:get_state(NodePid)),
    false = maps:is_key(<<"trust">>, Payload),
    [_ | _] = Peers = maps:get(<<"peers">>, Payload),
    [false = maps:is_key(<<"trust">>, P) || P <- Peers],
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
