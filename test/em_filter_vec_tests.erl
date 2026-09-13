-module(em_filter_vec_tests).
-include_lib("eunit/include/eunit.hrl").

%% 64 f32 little-endian floats = 256 bytes.
default_dim_bytes_test() ->
    V = em_filter_vec:from_capabilities([<<"search">>]),
    ?assertEqual(256, byte_size(V)).

unit_norm_test() ->
    V = em_filter_vec:from_capabilities([<<"rss">>, <<"search">>, <<"news">>]),
    Floats = [F || <<F:32/float-little>> <= V],
    SumSq = lists:foldl(fun(F, S) -> S + F * F end, 0.0, Floats),
    ?assert(abs(SumSq - 1.0) < 1.0e-5).

empty_is_uniform_unit_test() ->
    V = em_filter_vec:from_capabilities([]),
    Floats = [F || <<F:32/float-little>> <= V],
    %% all slots equal
    ?assertEqual(1, length(lists:usort([round(F * 1.0e6) || F <- Floats]))),
    SumSq = lists:foldl(fun(F, S) -> S + F * F end, 0.0, Floats),
    ?assert(abs(SumSq - 1.0) < 1.0e-5).

deterministic_test() ->
    A = em_filter_vec:from_capabilities([<<"images">>, <<"audio">>]),
    B = em_filter_vec:from_capabilities([<<"images">>, <<"audio">>]),
    ?assertEqual(A, B).

accepts_atoms_and_lists_test() ->
    V = em_filter_vec:from_capabilities([search, "rss", <<"news">>]),
    ?assertEqual(256, byte_size(V)).
