%%%-------------------------------------------------------------------
%%% @doc agent_router — semantic filter selection (the `select' phase
%%% meta-agent).
%%%
%%% Replaces the hash-based `emquest_pop:peers_for_query/2' selection
%%% with real embeddings: the raw query is embedded via `em_hf',
%%% every live peer's name is scored against `em_librarian''s index
%%% by cosine similarity, and the top-K peers are kept. `f40' now
%%% reaches the image filters by meaning, not by keyword overlap.
%%%
%%% === Guardrails (never worse than today) ===
%%%
%%% <ul>
%%%   <li>`em_hf:embed/1' failure (hf_topics down) => `skip'.</li>
%%%   <li>Empty final selection (no scored peer AND no media filter
%%%       live) => `skip', rather than handing back `peers => []'.</li>
%%%   <li>The media-bank filters (images/audio/video) are always
%%%       unioned in, exactly like `emquest_handler:ensure_media_peers/1'
%%%       does for the hash path today.</li>
%%% </ul>
%%%
%%% On `skip', `em_agent:run_phase/2' leaves `Ctx' unchanged, and
%%% `emquest_handler' falls back to `emquest_pop:peers_for_query/2' —
%%% today's exact behaviour.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_router).
-behaviour(em_agent).
-include_lib("kernel/include/logger.hrl").

-export([run/1]).
-export([select/2, cosine/2]).

-define(DEFAULT_K, 12).
-define(ALWAYS_MEDIA, [<<"openverse_filter">>, <<"wikimedia_commons_filter">>,
                        <<"artic_filter">>, <<"nasa_images_filter">>,
                        <<"sepiasearch_filter">>]).

%%--------------------------------------------------------------------
%% @doc `em_agent' callback. `Ctx' must contain a `query' binary.
%% @end
%%--------------------------------------------------------------------
-spec run(map()) -> {ok, map()} | skip.
run(#{query := Query} = Ctx) when is_binary(Query) ->
    case em_hf:embed(Query) of
        {ok, QVec} ->
            Peers = safe_all_peers(),
            Names = [N || P <- Peers,
                          (N = maps:get(name, P, <<>>)) =/= <<>>],
            catch em_librarian:ensure(Names),
            Index = em_librarian:index(),
            Selected = select(QVec, #{peers => Peers, index => Index,
                                       k => router_k()}),
            case Selected of
                [] -> skip;
                _  -> {ok, Ctx#{peers => Selected}}
            end;
        error ->
            skip
    end;
run(_Ctx) ->
    skip.

%%--------------------------------------------------------------------
%% @doc Pure selection: score every peer with an index entry by
%% cosine similarity to `QVec', take the top-K, then always union the
%% media-bank filters. No I/O — takes `peers'/`index' as injected
%% data so eunit can exercise it directly with fixtures.
%%
%% `Opts' = `#{peers := [PeerMap], index := #{Name => Vec},
%%             k => pos_integer()}' (`k' defaults to 12).
%%
%% Returns `[{PeerMap, Score}]' in the exact shape
%% `emquest_handler:spawn_pop_workers/3' consumes.
%% @end
%%--------------------------------------------------------------------
-spec select([float()], map()) -> [{map(), float()}].
select(QVec, Opts) ->
    Peers = maps:get(peers, Opts, []),
    Index = maps:get(index, Opts, #{}),
    K     = maps:get(k, Opts, ?DEFAULT_K),
    Scored = score_peers(QVec, Peers, Index),
    TopK   = top_k(Scored, K),
    with_media(TopK, Peers).

%%--------------------------------------------------------------------
%% @doc Cosine similarity of two equal-length float vectors. Returns
%% `0.0' on a dimension mismatch or a zero-norm vector rather than
%% raising — routing must degrade gracefully, never crash.
%% @end
%%--------------------------------------------------------------------
-spec cosine([float()], [float()]) -> float().
cosine(A, B) when is_list(A), is_list(B), length(A) =:= length(B) ->
    Dot = lists:sum(lists:zipwith(fun(X, Y) -> X * Y end, A, B)),
    NA  = math:sqrt(lists:sum([X * X || X <- A])),
    NB  = math:sqrt(lists:sum([X * X || X <- B])),
    Denom = NA * NB,
    if
        Denom < 1.0e-12, Denom > -1.0e-12 -> 0.0;
        true                              -> Dot / Denom
    end;
cosine(_, _) ->
    0.0.

%%====================================================================
%% Internal
%%====================================================================

%% @private
%% @doc Score every peer that has a `query_port' and an index entry
%% for its name. Peers with neither are simply not candidates for
%% semantic selection (they may still enter via `with_media/2').
score_peers(QVec, Peers, Index) ->
    lists:filtermap(fun(P) ->
        case maps:get(query_port, P, undefined) of
            undefined -> false;
            _ ->
                Name = maps:get(name, P, <<>>),
                case maps:get(Name, Index, undefined) of
                    undefined -> false;
                    Vec       -> {true, {P, cosine(QVec, Vec)}}
                end
        end
    end, Peers).

%% @private
top_k(Scored, K) ->
    Sorted = lists:sort(fun({_, S1}, {_, S2}) -> S1 >= S2 end, Scored),
    lists:sublist(Sorted, max(K, 0)).

%% @private
%% @doc Union in the always-on media-bank filters (images/audio/video)
%% from the live peer set, deduplicated by endpoint — same list and
%% same dedup rule as `emquest_handler:ensure_media_peers/1'.
with_media(Selected, Peers) ->
    SelKeys = [endpoint_key(P) || {P, _} <- Selected],
    Extra = [{P, 1.0}
             || P <- Peers,
                lists:member(maps:get(name, P, <<>>), ?ALWAYS_MEDIA),
                maps:get(query_port, P, undefined) =/= undefined,
                not lists:member(endpoint_key(P), SelKeys)],
    Selected ++ Extra.

%% @private
endpoint_key(P) ->
    {maps:get(host, P, undefined), maps:get(query_port, P, undefined)}.

%% @private
safe_all_peers() ->
    try emquest_pop:all_peers()
    catch _:_ -> []
    end.

%% @private
%% @doc `[agents] router_k' from `emergence.conf', default 12.
router_k() ->
    case maps:get("router_k", em_agent:conf(), undefined) of
        undefined -> ?DEFAULT_K;
        V when is_list(V) ->
            case string:to_integer(V) of
                {Int, _} when is_integer(Int), Int > 0 -> Int;
                _ -> ?DEFAULT_K
            end;
        _ -> ?DEFAULT_K
    end.
