-module(em_vec_tests).
-include_lib("eunit/include/eunit.hrl").

cosine_identical_test() ->
    ?assertEqual(1.0, em_vec:cosine([1.0, 0.0], [1.0, 0.0])).

cosine_orthogonal_test() ->
    ?assertEqual(0.0, em_vec:cosine([1.0, 0.0], [0.0, 1.0])).

cosine_opposite_test() ->
    ?assertEqual(-1.0, em_vec:cosine([1.0, 0.0], [-1.0, 0.0])).

cosine_length_mismatch_is_zero_test() ->
    ?assertEqual(0.0, em_vec:cosine([1.0], [1.0, 2.0])).

cosine_zero_vector_is_zero_test() ->
    ?assertEqual(0.0, em_vec:cosine([0.0, 0.0], [1.0, 0.0])).

dot_test() ->
    ?assertEqual(11.0, em_vec:dot([1.0, 2.0], [3.0, 4.0])).

dot_shorter_length_test() ->
    ?assertEqual(3.0, em_vec:dot([1.0, 2.0, 9.0], [3.0])).

dot_f32_roundtrip_test() ->
    A = << <<F:32/float-little>> || F <- [1.0, 0.0, 0.0] >>,
    B = << <<F:32/float-little>> || F <- [1.0, 0.0, 0.0] >>,
    ?assert(abs(em_vec:dot_f32(A, B) - 1.0) < 1.0e-6).
