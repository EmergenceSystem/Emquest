%%%-------------------------------------------------------------------
%%% @doc Unit tests for the pure helpers behind the gated /admin routes.
%%% The route/auth flow itself (cowboy dispatch, bearer-token gating,
%%% ban/unban/trust POST handling) can't be exercised without a live
%%% cowboy listener, so it isn't covered here — see emquest_admin_tests.erl
%%% for the authenticate/audit unit coverage that backs `admin_auth/1'.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_admin_route_tests).
-include_lib("eunit/include/eunit.hrl").

tier_test() ->
    ?assertEqual(<<"excluded">>,   emquest_handler:trust_tier(0.05)),
    ?assertEqual(<<"quarantine">>, emquest_handler:trust_tier(0.2)),
    ?assertEqual(<<"normal">>,     emquest_handler:trust_tier(0.9)).

peer_json_shape_test() ->
    J = emquest_handler:peer_admin_json(#{name => <<"x">>, trust => 0.5, query_port => 9101}),
    ?assertEqual(<<"normal">>, maps:get(<<"tier">>, J)),
    ?assertEqual(<<"x">>, maps:get(<<"name">>, J)),
    ?assertEqual(0.5, maps:get(<<"trust">>, J)),
    ?assertEqual(9101, maps:get(<<"query_port">>, J)),
    ?assertEqual(null, maps:get(<<"id">>, J)),
    ?assertEqual(false, maps:get(<<"banned">>, J)).

peer_json_defaults_test() ->
    J = emquest_handler:peer_admin_json(#{}),
    ?assertEqual(<<>>, maps:get(<<"name">>, J)),
    ?assertEqual(<<"excluded">>, maps:get(<<"tier">>, J)),
    ?assertEqual(null, maps:get(<<"query_port">>, J)).
