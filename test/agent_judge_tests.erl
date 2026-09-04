-module(agent_judge_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% reorder/3 — pure re-order by {judge_score, orig_score} descending
%%====================================================================

reorder_by_judge_score_desc_test() ->
    Sids      = [1, 2, 3],
    ScoresMap = #{<<"1">> => 10.0, <<"2">> => 20.0, <<"3">> => 30.0},
    JudgeMap  = #{<<"1">> => 3, <<"2">> => 0, <<"3">> => 1},
    %% Highest judge score wins even though its original score was
    %% lowest — this is the "arxiv/wikipedia rises above a generic
    %% image result" case.
    ?assertEqual([1, 3, 2], agent_judge:reorder(Sids, ScoresMap, JudgeMap)).

reorder_ties_broken_by_original_score_test() ->
    Sids      = [1, 2, 3],
    ScoresMap = #{<<"1">> => 5.0, <<"2">> => 50.0, <<"3">> => 20.0},
    JudgeMap  = #{<<"1">> => 2, <<"2">> => 2, <<"3">> => 2},
    ?assertEqual([2, 3, 1], agent_judge:reorder(Sids, ScoresMap, JudgeMap)).

reorder_missing_judge_entries_default_to_zero_test() ->
    Sids      = [1, 2],
    ScoresMap = #{<<"1">> => 5.0, <<"2">> => 1.0},
    %% Only sid 2 was actually rated; sid 1 is missing from JudgeMap
    %% (e.g. the model only rated a subset) and is demoted, not dropped.
    JudgeMap  = #{<<"2">> => 3},
    ?assertEqual([2, 1], agent_judge:reorder(Sids, ScoresMap, JudgeMap)).

reorder_empty_judge_map_is_identity_by_original_score_test() ->
    Sids      = [3, 1, 2],
    ScoresMap = #{<<"3">> => 5.0, <<"1">> => 20.0, <<"2">> => 10.0},
    ?assertEqual([1, 2, 3], agent_judge:reorder(Sids, ScoresMap, #{})).

reorder_never_drops_a_sid_test() ->
    Sids      = [1, 2, 3, 4, 5],
    ScoresMap = #{},
    JudgeMap  = #{<<"1">> => 3},
    Result = agent_judge:reorder(Sids, ScoresMap, JudgeMap),
    ?assertEqual(lists:sort(Sids), lists:sort(Result)),
    ?assertEqual(5, length(Result)).

%%====================================================================
%% parse_judge_scores/1 — well-formed responses
%%====================================================================

parse_judge_scores_well_formed_test() ->
    Text = <<"{\"12\": 3, \"7\": 0, \"9\": 1}">>,
    ?assertEqual({ok, #{<<"12">> => 3, <<"7">> => 0, <<"9">> => 1}},
                 agent_judge:parse_judge_scores(Text)).

parse_judge_scores_strips_markdown_fences_test() ->
    Text = <<"```json\n{\"1\": 2}\n```">>,
    ?assertEqual({ok, #{<<"1">> => 2}}, agent_judge:parse_judge_scores(Text)).

parse_judge_scores_clamps_out_of_range_test() ->
    Text = <<"{\"1\": 99, \"2\": -5}">>,
    ?assertEqual({ok, #{<<"1">> => 3, <<"2">> => 0}},
                 agent_judge:parse_judge_scores(Text)).

parse_judge_scores_drops_non_integer_values_test() ->
    Text = <<"{\"1\": \"high\", \"2\": 2}">>,
    ?assertEqual({ok, #{<<"2">> => 2}}, agent_judge:parse_judge_scores(Text)).

%%====================================================================
%% parse_judge_scores/1 — malformed responses => error (the caller's
%% "identity fallback": `run/1' returns `skip', existing order kept)
%%====================================================================

parse_judge_scores_not_json_returns_error_test() ->
    ?assertEqual(error, agent_judge:parse_judge_scores(<<"not json at all">>)).

parse_judge_scores_json_array_returns_error_test() ->
    %% An array (not an object) — same shape mismatch a real qwen2.5:3b
    %% slip could produce.
    ?assertEqual(error, agent_judge:parse_judge_scores(<<"[1, 2, 3]">>)).

parse_judge_scores_empty_text_returns_error_test() ->
    ?assertEqual(error, agent_judge:parse_judge_scores(<<>>)).
