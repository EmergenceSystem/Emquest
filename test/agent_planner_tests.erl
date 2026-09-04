-module(agent_planner_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% parse_subqueries/2 — well-formed responses
%%====================================================================

parse_well_formed_json_array_test() ->
    Text = <<"[\"quantum mechanics\", \"quantum field theory\"]">>,
    Result = agent_planner:parse_subqueries(Text, <<"quantum physics">>),
    ?assertEqual([<<"quantum physics">>, <<"quantum field theory">>,
                  <<"quantum mechanics">>],
                 Result).

parse_strips_markdown_fences_test() ->
    Text = <<"```json\n[\"a\", \"b\"]\n```">>,
    Result = agent_planner:parse_subqueries(Text, <<"q">>),
    ?assertEqual([<<"q">>, <<"a">>, <<"b">>], Result).

parse_dedupes_and_keeps_query_first_test() ->
    Text = <<"[\"q\", \"a\", \"q\", \"a\"]">>,
    Result = agent_planner:parse_subqueries(Text, <<"q">>),
    ?assertEqual([<<"q">>, <<"a">>], Result).

parse_caps_at_five_subqueries_test() ->
    Text = <<"[\"a\", \"b\", \"c\", \"d\", \"e\", \"f\", \"g\"]">>,
    Result = agent_planner:parse_subqueries(Text, <<"q">>),
    ?assertEqual(5, length(Result)),
    ?assertEqual(<<"q">>, hd(Result)).

parse_drops_non_string_entries_test() ->
    Text = <<"[\"a\", 3, null, \"b\"]">>,
    Result = agent_planner:parse_subqueries(Text, <<"q">>),
    ?assertEqual([<<"q">>, <<"a">>, <<"b">>], Result).

%%====================================================================
%% parse_subqueries/2 — malformed responses => [] (caller falls back
%% to queen:expand/1)
%%====================================================================

parse_malformed_not_json_returns_empty_test() ->
    ?assertEqual([], agent_planner:parse_subqueries(<<"not json at all">>, <<"q">>)).

parse_malformed_json_object_returns_empty_test() ->
    ?assertEqual([], agent_planner:parse_subqueries(<<"{\"a\": 1}">>, <<"q">>)).

parse_malformed_empty_array_returns_empty_test() ->
    ?assertEqual([], agent_planner:parse_subqueries(<<"[]">>, <<"q">>)).

parse_malformed_all_non_strings_returns_empty_test() ->
    ?assertEqual([], agent_planner:parse_subqueries(<<"[1, 2, null]">>, <<"q">>)).

parse_malformed_all_empty_strings_returns_empty_test() ->
    ?assertEqual([], agent_planner:parse_subqueries(<<"[\"\", \"\"]">>, <<"q">>)).
