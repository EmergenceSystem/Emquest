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
-export([greedy_dedup/2]).

-define(DEFAULT_WINDOW, 40).
-define(DEFAULT_THRESHOLD, 0.90).

-spec run(map()) -> {ok, map()} | skip.
run(#{sortedsids := Sids, items := ItemsBySid} = Ctx)
  when is_list(Sids), is_map(ItemsBySid) ->
    {Head, Tail} = split(Sids, window()),
    case Head of
        [] -> skip;
        _  ->
            Docs = [em_agent:doc_text(maps:get(S, ItemsBySid, #{})) || S <- Head],
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
            case lists:any(fun(KV) -> em_vec:cosine(Vec, KV) >= Thresh end, VAcc) of
                true  -> {KAcc, VAcc};
                false -> {[Sid | KAcc], [Vec | VAcc]}
            end
        end, {[], []}, Pairs),
    lists:reverse(Kept).

%%====================================================================
%% Internal
%%====================================================================

%% @private
split(L, N) ->
    K = min(max(N, 0), length(L)),
    lists:split(K, L).

%% @private `[agents] dedup_window', default 40.
window() -> emconf:get_int("agents", "dedup_window", ?DEFAULT_WINDOW).

%% @private `[agents] dedup_threshold', default 0.90.
threshold() -> emconf:get_float("agents", "dedup_threshold", ?DEFAULT_THRESHOLD).
