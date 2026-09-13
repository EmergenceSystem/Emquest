%%%-------------------------------------------------------------------
%%% @doc agent_judge — cross-encoder re-rank of the top-N results (the
%%% `rerank' phase meta-agent).
%%%
%%% Runs after `emquest_handler:aggregate_and_rank/3', before
%%% `sse_reorder/3'. Takes the current top-N ranked sids (config
%%% `judge_top_n', default 20) and re-orders them by the relevance
%%% score `em_hf:rerank/2' assigns each `{query, document}' pair.
%%%
%%% This is a **soft** re-rank: it never drops a sid. Everything past
%%% the top-N is left untouched and appended after the re-ordered head.
%%%
%%% === Guardrails (never worse than today) ===
%%%
%%% <ul>
%%%   <li>reranker down / any error / a score count that doesn't match
%%%       the head => `skip'.</li>
%%% </ul>
%%%
%%% On `skip', `em_agent:run_phase/2' leaves `Ctx' unchanged, and
%%% `emquest_handler' streams `SortedSids'/`ScoresMap' exactly as
%%% `aggregate_and_rank/3' produced them.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_judge).
-behaviour(em_agent).
-include_lib("kernel/include/logger.hrl").

-export([run/1]).
-export([reorder_ce/2]).

-define(DEFAULT_TOP_N, 20).

%%--------------------------------------------------------------------
%% @doc `em_agent' callback. `Ctx' must contain:
%% <ul>
%%   <li>`query' — the original query binary</li>
%%   <li>`sortedsids' — `[Sid]', best-first, from `aggregate_and_rank/3'</li>
%%   <li>`scores' — `#{binary(Sid) => number()}', the existing scores</li>
%%   <li>`items' — `#{Sid => RawItem}', a lookup for the item behind
%%       each sid (built by `emquest_handler' from `TaggedItems')</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
-spec run(map()) -> {ok, map()} | skip.
run(#{query := Query, sortedsids := SortedSids, scores := ScoresMap,
      items := ItemsBySid} = Ctx)
  when is_binary(Query), is_list(SortedSids), is_map(ScoresMap),
       is_map(ItemsBySid) ->
    _ = ScoresMap,
    {Head, Tail} = split_top(SortedSids, judge_top_n()),
    case Head of
        [] -> skip;
        _  ->
            Docs = [em_agent:doc_text(maps:get(Sid, ItemsBySid, #{})) || Sid <- Head],
            case em_hf:rerank(Query, Docs) of
                {ok, Scores} when length(Scores) =:= length(Head) ->
                    {ok, Ctx#{sortedsids => reorder_ce(Head, Scores) ++ Tail}};
                _ ->
                    skip
            end
    end;
run(_Ctx) ->
    skip.

%%--------------------------------------------------------------------
%% @doc Re-order `Sids' by descending cross-encoder score (`Scores' is
%% aligned with `Sids'). Ties keep the original best-first order. Pure.
%% @end
%%--------------------------------------------------------------------
-spec reorder_ce([non_neg_integer()], [float()]) -> [non_neg_integer()].
reorder_ce(Sids, Scores) ->
    Indexed = lists:zip3(Sids, Scores, lists:seq(1, length(Sids))),
    Sorted  = lists:sort(fun({_, S1, P1}, {_, S2, P2}) ->
                             {S1, -P1} >= {S2, -P2}
                         end, Indexed),
    [Sid || {Sid, _, _} <- Sorted].

%%====================================================================
%% Internal
%%====================================================================

%% @private
split_top(Sids, N) ->
    K = min(max(N, 0), length(Sids)),
    lists:split(K, Sids).

%% @private `[agents] judge_top_n' from `emergence.conf', default 20.
judge_top_n() -> emconf:get_int("agents", "judge_top_n", ?DEFAULT_TOP_N).
