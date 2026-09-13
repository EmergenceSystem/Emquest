-module(agent_judge_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% reorder_ce/2 — pure re-order by descending cross-encoder score
%%====================================================================

reorder_ce_by_score_desc_test() ->
    Sids   = [1, 2, 3],
    Scores = [0.1, 0.9, 0.5],
    %% Highest score first, regardless of original position.
    ?assertEqual([2, 3, 1], agent_judge:reorder_ce(Sids, Scores)).

reorder_ce_ties_keep_original_order_test() ->
    Sids   = [1, 2, 3],
    Scores = [0.5, 0.5, 0.9],
    %% 3 wins; the 1/2 tie keeps their original best-first order.
    ?assertEqual([3, 1, 2], agent_judge:reorder_ce(Sids, Scores)).

reorder_ce_already_sorted_is_identity_test() ->
    Sids   = [1, 2, 3],
    Scores = [0.9, 0.5, 0.1],
    ?assertEqual([1, 2, 3], agent_judge:reorder_ce(Sids, Scores)).

reorder_ce_never_drops_a_sid_test() ->
    Sids   = [1, 2, 3, 4],
    Scores = [0.2, 0.2, 0.2, 0.2],
    Result = agent_judge:reorder_ce(Sids, Scores),
    ?assertEqual(lists:sort(Sids), lists:sort(Result)),
    ?assertEqual(length(Sids), length(Result)).
