%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_pop — Emquest's Population Protocol node manager.
%%%
%%% Owns one `em_pop_node' gen_server on behalf of Emquest.  That node
%%% maintains a peer table of up to 5 000 em_filter agents, updated
%%% continuously by background gossip.  emquest_pop exposes a single
%%% public function, `peers_for_query/2', which the Emquest pipeline
%%% calls to obtain the K most semantically relevant agents for direct
%%% HTTP dispatch.
%%%
%%% === Startup ===
%%%
%%% The gen_server starts an em_pop_node listening on `pop_port'
%%% (from `[emquest] pop_port' in emergence.conf, default 9100).
%%% It then contacts each `{Host, PopPort}' from `queen:pop_seeds/0'
%%% to seed the peer table.  Bootstrap failures are caught — they do
%%% not abort startup.
%%%
%%% === Routing ===
%%%
%%% `peers_for_query(QueryVec, K)' performs:
%%%   1. kvex cosine search over the peer table for the top K*3 hits.
%%%   2. Filters to peers that advertise a `query_port' (non-undefined).
%%%   3. Returns at most K `{PeerMap, Score}' pairs.
%%%
%%% Peers without `query_port' are excluded because Emquest cannot
%%% reach them via direct HTTP — they remain reachable via the
%%% WebSocket bus (Phase 2 fallback path).
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_pop).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, peers_for_query/2, all_peers/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Maximum number of peers this node maintains.
-define(MAX_PEERS, 5_000).

%% Capability label for Emquest's em_pop node.
-define(EMQUEST_CAPS, [<<"search">>]).

%%--------------------------------------------------------------------
%% @doc Start and globally register the Emquest em_pop manager.
%%
%% Call this once at application boot via `emquest_sup'.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

%%--------------------------------------------------------------------
%% @doc Return the top-K agents most similar to QueryVec that expose
%% a `query_port' for direct HTTP dispatch.
%%
%% Returns `[{PeerMap, Score}]' ordered by descending cosine similarity.
%% Returns `[]' when the peer table is empty (normal at startup before
%% the first gossip round completes).
%%
%% Peers without `query_port' are silently excluded.
%% @end
%%--------------------------------------------------------------------
-spec peers_for_query(binary(), pos_integer()) ->
    [{map(), float()}].
peers_for_query(QueryVec, K) ->
    gen_server:call(?MODULE, {peers_for_query, QueryVec, K}, 15_000).

%%--------------------------------------------------------------------
%% @doc Return all known em_pop peers (used by the network view).
%%
%% Returns `[PeerMap]' — the full peer table up to MAX_PEERS entries,
%% scored by similarity to the emquest capability vector so that the
%% most relevant peers appear first. Returns `[]' when degraded.
%% @end
%%--------------------------------------------------------------------
-spec all_peers() -> [map()].
all_peers() ->
    gen_server:call(?MODULE, all_peers, 5_000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    application:ensure_all_started(inets),
    Port  = maps:get(pop_port, Opts, queen:emquest_pop_port()),
    Vec   = em_filter_vec:from_capabilities(?EMQUEST_CAPS),
    Seeds = maps:get(seeds, Opts, queen:pop_seeds()),
    NodeOpts = #{port            => Port,
                 vector          => Vec,
                 seeds           => Seeds,
                 max_peers       => ?MAX_PEERS,
                 gossip_interval => 5_000,
                 stale_timeout   => 300_000},  %% 5 min: full round with 30 peers at 5s/peer = 150s
    case em_pop_node:start_link(NodeOpts) of
        {ok, NodePid} ->
            lists:foreach(fun({H, P}) ->
                catch em_pop_node:add_peer(NodePid, H, P)
            end, Seeds),
            ?LOG_INFO("[emquest_pop] started on port ~w, ~w seed(s)",
                      [Port, length(Seeds)]),
            {ok, #{node => NodePid}};
        {error, Reason} ->
            ?LOG_WARNING("[emquest_pop] em_pop_node failed to start on port ~w,"
                         " running degraded (no em_pop routing): ~p",
                         [Port, Reason]),
            {ok, #{node => undefined}}
    end.

handle_call({peers_for_query, _QueryVec, _K}, _From,
            #{node := undefined} = State) ->
    %% Degraded mode — em_pop_node failed to start.
    {reply, [], State};

handle_call({peers_for_query, QueryVec, K}, _From,
            #{node := Node} = State) ->
    Candidates = em_pop_node:peers_for(Node, QueryVec, K * 3),
    Routable = [{PeerMap, Score}
                || {PeerMap, Score} <- Candidates,
                   maps:get(query_port, PeerMap, undefined) =/= undefined],
    Unique = dedup_by_endpoint(Routable),
    {reply, lists:sublist(Unique, K), State};

handle_call(all_peers, _From, #{node := undefined} = State) ->
    {reply, [], State};
handle_call(all_peers, _From, #{node := Node} = State) ->
    Vec = em_filter_vec:from_capabilities(?EMQUEST_CAPS),
    Candidates = em_pop_node:peers_for(Node, Vec, ?MAX_PEERS),
    {reply, [P || {P, _Score} <- Candidates], State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Msg, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

%%====================================================================
%% Internal
%%====================================================================

%% @private
%% @doc Deduplicate a scored peer list by {host, query_port}.
%%
%% Preserves order (best score first). When two entries share the same
%% physical endpoint the first one (highest-scoring) is kept, which
%% happens when a filter agent was restarted and gossip still carries
%% both the old and the new ID.
%% @end
-spec dedup_by_endpoint([{map(), float()}]) -> [{map(), float()}].
dedup_by_endpoint(Peers) ->
    dedup_by_endpoint(Peers, sets:new([{version, 2}]), []).

dedup_by_endpoint([], _Seen, Acc) ->
    lists:reverse(Acc);
dedup_by_endpoint([{PeerMap, Score} | Rest], Seen, Acc) ->
    Key = {maps:get(host, PeerMap, undefined),
           maps:get(query_port, PeerMap, undefined)},
    case sets:is_element(Key, Seen) of
        true  -> dedup_by_endpoint(Rest, Seen, Acc);
        false -> dedup_by_endpoint(Rest, sets:add_element(Key, Seen),
                                   [{PeerMap, Score} | Acc])
    end.
