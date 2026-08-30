%%%-------------------------------------------------------------------
%%% @doc agent_judge — LLM re-rank of the top-N results (the `rerank'
%%% phase meta-agent).
%%%
%%% Runs after `emquest_handler:aggregate_and_rank/3', before
%%% `sse_reorder/3'. Takes the current top-N ranked sids (config
%%% `judge_top_n', default 20), asks ollama to rate each 0–3 for
%%% relevance to the original query, and re-orders them by
%%% `{JudgeScore, OriginalScore}' descending.
%%%
%%% This is a **soft** re-rank: it never drops a sid (qwen2.5:3b is a
%%% small local model, dropping results on its say-so is too risky).
%%% Everything past the top-N is left untouched and appended after the
%%% re-ordered head.
%%%
%%% === Guardrails (never worse than today) ===
%%%
%%% <ul>
%%%   <li>ollama timeout / down / any error from `call_handler_timeout/4'
%%%       => `skip'.</li>
%%%   <li>Non-JSON or non-object response => `skip'.</li>
%%%   <li>Individual malformed scores inside an otherwise valid JSON
%%%       object (wrong type, out of 0–3 range) are dropped and treated
%%%       as unscored (0), rather than failing the whole call.</li>
%%% </ul>
%%%
%%% On `skip', `em_agent:run_phase/2' leaves `Ctx' unchanged, and
%%% `emquest_handler' streams `SortedSids'/`ScoresMap' exactly as
%%% `aggregate_and_rank/3' produced them — today's exact behaviour.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_judge).
-behaviour(em_agent).
-include_lib("kernel/include/logger.hrl").

-export([run/1]).
-export([reorder/3, reorder_ce/2, parse_judge_scores/1]).

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
            Docs = [doc_text(maps:get(Sid, ItemsBySid, #{})) || Sid <- Head],
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
%% @doc Re-order `Sids' by `{JudgeScore, OriginalScore}' descending.
%% Sids absent from `JudgeMap' default to judge score 0 (demoted
%% behind anything the model actually rated, but never dropped). Pure
%% — no I/O — so eunit can exercise it directly with fixtures.
%% @end
%%--------------------------------------------------------------------
-spec reorder([non_neg_integer()], map(), map()) -> [non_neg_integer()].
reorder(Sids, ScoresMap, JudgeMap) ->
    Scored = [{Sid, maps:get(sid_key(Sid), JudgeMap, 0),
               maps:get(sid_key(Sid), ScoresMap, 0)} || Sid <- Sids],
    Sorted = lists:sort(fun({_, J1, O1}, {_, J2, O2}) ->
                            {J1, O1} >= {J2, O2}
                         end, Scored),
    [Sid || {Sid, _, _} <- Sorted].

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

%% @private Title + resume text for a raw item (same shape as the
%% router/dedup use), fed to the cross-encoder as the document side.
doc_text(Item) ->
    Props = maps:get(<<"properties">>, Item, Item),
    L = to_bin(maps:get(<<"title">>,  Props, maps:get(<<"label">>, Props, <<>>))),
    V = to_bin(maps:get(<<"resume">>, Props, maps:get(<<"value">>, Props, <<>>))),
    case V of <<>> -> L; _ -> <<L/binary, " ", V/binary>> end.

%% @private
to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<>>.

%%--------------------------------------------------------------------
%% @doc Parse ollama's `{"sid": score, ...}' response text into
%% `#{binary() => 0..3}'. Returns `error' when the response isn't a
%% JSON object at all (identity-fallback case) — individual bad
%% entries (wrong type, out-of-range score) are silently dropped
%% rather than failing the whole parse. Pure — no I/O — so eunit can
%% exercise it directly with well-formed and malformed fixtures.
%% @end
%%--------------------------------------------------------------------
-spec parse_judge_scores(binary()) -> {ok, #{binary() => 0..3}} | error.
parse_judge_scores(Text) ->
    try json:decode(strip_fences(Text)) of
        Decoded when is_map(Decoded) ->
            {ok, maps:fold(fun(K, V, Acc) ->
                case {norm_key(K), norm_score(V)} of
                    {Key, Score} when Key =/= undefined, Score =/= undefined ->
                        Acc#{Key => Score};
                    _ ->
                        Acc
                end
            end, #{}, Decoded)};
        _ ->
            error
    catch _:_ -> error
    end.

%%====================================================================
%% Internal
%%====================================================================

%% @private
split_top(Sids, N) ->
    K = min(max(N, 0), length(Sids)),
    lists:split(K, Sids).

%% @private
%% @doc `[agents] judge_top_n' from `emergence.conf', default 20.
judge_top_n() ->
    case maps:get("judge_top_n", em_agent:conf(), undefined) of
        undefined -> ?DEFAULT_TOP_N;
        V when is_list(V) ->
            case string:to_integer(V) of
                {Int, _} when is_integer(Int), Int > 0 -> Int;
                _ -> ?DEFAULT_TOP_N
            end;
        _ -> ?DEFAULT_TOP_N
    end.

%% @private
sid_key(Sid) when is_integer(Sid) -> integer_to_binary(Sid);
sid_key(Sid) when is_binary(Sid)  -> Sid.

%% @private
norm_key(K) when is_binary(K) -> K;
norm_key(K) when is_atom(K)   -> atom_to_binary(K, utf8);
norm_key(K) when is_integer(K) -> integer_to_binary(K);
norm_key(_) -> undefined.

%% @private
norm_score(V) when is_integer(V), V >= 0, V =< 3 -> V;
norm_score(V) when is_integer(V), V < 0 -> 0;
norm_score(V) when is_integer(V), V > 3 -> 3;
norm_score(V) when is_float(V) -> norm_score(round(V));
norm_score(_) -> undefined.

%% @private Strip ```json ... ``` / ``` ... ``` markdown fences some
%% models wrap JSON in despite the "no markdown" instruction.
-spec strip_fences(binary()) -> binary().
strip_fences(Text) ->
    T1 = re:replace(Text, <<"^```(json)?\\s*">>, <<"">>,
                    [{return, binary}, multiline]),
    re:replace(T1, <<"\\s*```$">>, <<"">>,
               [{return, binary}, multiline]).
