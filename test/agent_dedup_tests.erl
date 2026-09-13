-module(agent_dedup_tests).
-include_lib("eunit/include/eunit.hrl").

%% Two near-identical vectors (cosine 1.0) — second dropped.
drops_near_duplicate_test() ->
    Pairs = [{1, [1.0, 0.0]}, {2, [1.0, 0.0]}, {3, [0.0, 1.0]}],
    ?assertEqual([1, 3], agent_dedup:greedy_dedup(Pairs, 0.9)).

keeps_distinct_test() ->
    Pairs = [{1, [1.0, 0.0]}, {2, [0.0, 1.0]}],
    ?assertEqual([1, 2], agent_dedup:greedy_dedup(Pairs, 0.9)).

keeps_first_of_group_test() ->
    %% 1 and 3 identical; 1 (first) kept, 3 dropped; 2 distinct kept.
    Pairs = [{1, [1.0, 0.0]}, {2, [0.0, 1.0]}, {3, [1.0, 0.0]}],
    ?assertEqual([1, 2], agent_dedup:greedy_dedup(Pairs, 0.9)).

threshold_respected_test() ->
    %% cosine ~0.7 < 0.9 threshold => both kept.
    Pairs = [{1, [1.0, 0.0]}, {2, [1.0, 1.0]}],
    ?assertEqual([1, 2], agent_dedup:greedy_dedup(Pairs, 0.9)).

empty_test() ->
    ?assertEqual([], agent_dedup:greedy_dedup([], 0.9)).
