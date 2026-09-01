%%%-------------------------------------------------------------------
%%% @doc agent_dedup - semantic near-duplicate removal (`rerank' phase,
%%% runs before `agent_judge').
%%%
%%% Aggregation pulls the same subject from many sources, producing
%%% near-identical cards. This meta-agent embeds the top window of
%%% ranked items (hf_topics `/embed', the same bi-encoder the router
%%% uses) and greedily drops any whose cosine similarity to an
%%% already-kept item exceeds `[agents] dedup_threshold'. Order is
%%% preserved; the highest-ranked member of each near-duplicate group
%%% survives.
%%%
%%% Guardrails: embedding service down / mismatched response => `skip'
%%% (Ctx unchanged, today's ranking). Only the top `dedup_window'
%%% items are considered; the tail is passed through untouched.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_dedup).
-behaviour(em_agent).

-export([run/1]).
-export([greedy_dedup/2, cosine/2]).

-define(DEFAULT_WINDOW, 40).
-define(DEFAULT_THRESHOLD, 0.90).

-spec run(map()) -> {ok, map()} | skip.
run(#{sortedsids := Sids, items := ItemsBySid} = Ctx)
  when is_list(Sids), is_map(ItemsBySid) ->
    {Head, Tail} = split(Sids, window()),
    case Head of
        [] -> skip;
        _  ->
            Docs = [doc_text(maps:get(S, ItemsBySid, #{})) || S <- Head],
            case em_hf:embed_many(Docs) of
                {ok, Vecs} when length(Vecs) =:= length(Head) ->
                    Kept   = greedy_dedup(lists:zip(Head, Vecs), threshold()),
                    EmbMap = maps:from_list(lists:zip(Head, Vecs)),
                    Old    = maps:get(embeddings, Ctx, #{}),
                    {ok, Ctx#{sortedsids  => Kept ++ Tail,
                              embeddings  => maps:merge(Old, EmbMap)}};
                _ -> skip
            end
    end;
run(_) -> skip.

%%--------------------------------------------------------------------
%% @doc Greedy keep-first dedup. Walks `{Sid, Vec}' pairs best-first;
%% keeps a pair unless its vector is >= `Thresh' cosine to a kept one.
%% Pure - eunit-friendly.
%% @end
%%--------------------------------------------------------------------
-spec greedy_dedup([{non_neg_integer(), [float()]}], float())
        -> [non_neg_integer()].
greedy_dedup(Pairs, Thresh) ->
    {Kept, _} = lists:foldl(
        fun({Sid, Vec}, {KAcc, VAcc}) ->
            case lists:any(fun(KV) -> cosine(Vec, KV) >= Thresh end, VAcc) of
                true  -> {KAcc, VAcc};
                false -> {[Sid | KAcc], [Vec | VAcc]}
            end
        end, {[], []}, Pairs),
    lists:reverse(Kept).

%%--------------------------------------------------------------------
%% @doc Cosine similarity of two equal-length float vectors. `0.0'
%% when either is a zero vector.
%% @end
%%--------------------------------------------------------------------
-spec cosine([float()], [float()]) -> float().
cosine(A, B) ->
    Dot = dot(A, B, 0.0),
    Na  = math:sqrt(dot(A, A, 0.0)),
    Nb  = math:sqrt(dot(B, B, 0.0)),
    case Na * Nb of
        +0.0 -> 0.0;
        D   -> Dot / D
    end.

%%====================================================================
%% Internal
%%====================================================================

%% @private
dot([X | Xs], [Y | Ys], Acc) -> dot(Xs, Ys, Acc + X * Y);
dot(_, _, Acc) -> Acc.

%% @private
split(L, N) ->
    K = min(max(N, 0), length(L)),
    lists:split(K, L).

%% @private
doc_text(Item) ->
    Props = maps:get(<<"properties">>, Item, Item),
    L = to_bin(maps:get(<<"title">>,  Props, maps:get(<<"label">>, Props, <<>>))),
    V = to_bin(maps:get(<<"resume">>, Props, maps:get(<<"value">>, Props, <<>>))),
    case V of <<>> -> L; _ -> <<L/binary, " ", V/binary>> end.

%% @private
to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<>>.

%% @private `[agents] dedup_window', default 40.
window() -> int_conf("dedup_window", ?DEFAULT_WINDOW).

%% @private `[agents] dedup_threshold', default 0.90.
threshold() -> float_conf("dedup_threshold", ?DEFAULT_THRESHOLD).

%% @private
int_conf(K, D) ->
    case maps:get(K, em_agent:conf(), undefined) of
        undefined -> D;
        V when is_list(V) ->
            case string:to_integer(V) of
                {I, _} when is_integer(I), I > 0 -> I;
                _ -> D
            end;
        _ -> D
    end.

%% @private
float_conf(K, D) ->
    case maps:get(K, em_agent:conf(), undefined) of
        undefined -> D;
        V when is_list(V) ->
            case string:to_float(V) of
                {F, _} when is_float(F) -> F;
                _ -> D
            end;
        _ -> D
    end.
