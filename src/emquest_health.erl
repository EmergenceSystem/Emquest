%%%-------------------------------------------------------------------
%%% @doc emquest_health - active peer liveness monitor.
%%%
%%% Every 30s, TCP-probes each known peer's query port in parallel and
%%% keeps a per-peer health record (alive, latency, consecutive fails,
%%% last-ok). Peers that miss 3 probes in a row are marked dead; the
%%% query pipeline calls `filter_live/1' to stop routing to them (so a
%%% dead/ghost filter no longer drags every query to the fan-out
%%% timeout), and `/status' renders the health map as a dashboard.
%%%
%%% A TCP connect (not an /agent/query) is used as the probe so it is
%%% cheap and never triggers a filter's upstream API calls. Everything
%%% is best-effort: if the monitor is unavailable, `filter_live/1'
%%% keeps all peers (today's behaviour).
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_health).
-behaviour(gen_server).

-export([start_link/0, status/0, dead/0, filter_live/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(INTERVAL, 30000).
-define(PROBE_TIMEOUT, 1000).
-define(DEAD_FAILS, 3).
-define(FIRST_DELAY, 3000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Per-peer health maps (values of the internal table).
status() -> try gen_server:call(?MODULE, status, 5000) catch _:_ -> [] end.

%% @doc Set of dead endpoint keys `{HostString, Port}', or `undefined'
%% when the monitor is not ready (caller then keeps every peer).
dead() -> try gen_server:call(?MODULE, dead, 5000) catch _:_ -> undefined end.

%% @doc Drop known-dead peers from a `[PeerMap | {PeerMap, Score}]'
%% list; unknown/alive peers are kept.
filter_live(Peers) ->
    case dead() of
        undefined -> Peers;
        Dead      -> [PS || PS <- Peers,
                            not sets:is_element(peer_key(el(PS)), Dead)]
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    erlang:send_after(?FIRST_DELAY, self(), probe),
    {ok, #{health => #{}}}.

handle_call(status, _From, #{health := H} = S) ->
    {reply, maps:values(H), S};
handle_call(dead, _From, #{health := H} = S) ->
    Dead = sets:from_list([K || {K, #{fails := F}} <- maps:to_list(H),
                                F >= ?DEAD_FAILS]),
    {reply, Dead, S};
handle_call(_, _, S) -> {reply, ok, S}.

handle_cast(_, S) -> {noreply, S}.

handle_info(probe, #{health := H0} = S) ->
    Peers = try emquest_pop:all_peers() catch _:_ -> [] end,
    H1 = probe_all(Peers, H0),
    erlang:send_after(?INTERVAL, self(), probe),
    {noreply, S#{health => H1}};
handle_info(_, S) -> {noreply, S}.

terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

%%====================================================================
%% Internal
%%====================================================================

%% @private
el({PeerMap, _Score}) -> PeerMap;
el(PeerMap)           -> PeerMap.

%% @private
probe_all(Peers, H0) ->
    Self = self(),
    Reqs = lists:map(fun(P) ->
        K   = peer_key(P),
        Ref = make_ref(),
        spawn(fun() -> Self ! {pr, Ref, probe_one(K)} end),
        {Ref, K, P}
    end, Peers),
    Res = gather([R || {R, _, _} <- Reqs], #{}),
    maps:from_list(
        [{K, entry(K, P, maps:get(Ref, Res, fail), maps:get(K, H0, #{}))}
         || {Ref, K, P} <- Reqs]).

%% @private
gather([], Acc) -> Acc;
gather(Refs, Acc) ->
    receive
        {pr, Ref, R} -> gather(lists:delete(Ref, Refs), Acc#{Ref => R})
    after ?PROBE_TIMEOUT + 1000 -> Acc
    end.

%% @private
probe_one({Host, Port}) when is_integer(Port), Host =/= "" ->
    T0 = erlang:monotonic_time(millisecond),
    case gen_tcp:connect(Host, Port, [binary, {active, false}], ?PROBE_TIMEOUT) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            {ok, erlang:monotonic_time(millisecond) - T0};
        _ -> fail
    end;
probe_one(_) -> fail.

%% @private
entry(K, P, Res, Old) ->
    {Host, Port} = K,
    Name  = maps:get(name, P, <<>>),
    HostB = list_to_binary(Host),
    case Res of
        {ok, L} ->
            #{name => Name, host => HostB, port => Port, alive => true,
              latency => L, fails => 0, last_ok => now_s()};
        _ ->
            Fails = maps:get(fails, Old, 0) + 1,
            #{name => Name, host => HostB, port => Port,
              alive => Fails < ?DEAD_FAILS,
              latency => maps:get(latency, Old, null),
              fails => Fails, last_ok => maps:get(last_ok, Old, null)}
    end.

%% @private
peer_key(PeerMap) ->
    {host_str(maps:get(host, PeerMap, <<>>)),
     maps:get(query_port, PeerMap, undefined)}.

%% @private
host_str(B) when is_binary(B) -> binary_to_list(B);
host_str(L) when is_list(L)   -> L;
host_str(_)                   -> "".

%% @private
now_s() -> erlang:system_time(second).
