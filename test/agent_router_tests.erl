-module(agent_router_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% cosine/2
%%====================================================================

cosine_identical_vectors_is_one_test() ->
    ?assertEqual(1.0, agent_router:cosine([1.0, 0.0], [1.0, 0.0])).

cosine_orthogonal_vectors_is_zero_test() ->
    ?assertEqual(0.0, agent_router:cosine([1.0, 0.0], [0.0, 1.0])).

cosine_opposite_vectors_is_minus_one_test() ->
    ?assertEqual(-1.0, agent_router:cosine([1.0, 0.0], [-1.0, 0.0])).

cosine_dimension_mismatch_returns_zero_test() ->
    ?assertEqual(0.0, agent_router:cosine([1.0], [1.0, 2.0])).

cosine_zero_vector_returns_zero_test() ->
    ?assertEqual(0.0, agent_router:cosine([0.0, 0.0], [1.0, 0.0])).

%%====================================================================
%% select/2 — top-K semantic selection
%%====================================================================

peer(Name, Host, Port) ->
    #{name => Name, host => Host, query_port => Port}.

names(Selected) ->
    [maps:get(name, P) || {P, _Score} <- Selected].

select_top_k_by_cosine_test() ->
    Peers = [peer(<<"a">>, <<"h1">>, 1),
             peer(<<"b">>, <<"h2">>, 2),
             peer(<<"c">>, <<"h3">>, 3)],
    Index = #{<<"a">> => [1.0, 0.0],
              <<"b">> => [0.0, 1.0],
              <<"c">> => [0.9, 0.1]},
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => Index, k => 2}),
    %% "a" is an exact match, "c" is close, "b" is orthogonal — top-2 are
    %% a and c, in that order.
    ?assertEqual([<<"a">>, <<"c">>], names(Selected)).

select_excludes_peers_without_query_port_test() ->
    Peers = [peer(<<"a">>, <<"h1">>, 1),
             maps:remove(query_port, peer(<<"b">>, <<"h2">>, 2))],
    Index = #{<<"a">> => [1.0, 0.0], <<"b">> => [1.0, 0.0]},
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => Index, k => 5}),
    ?assertEqual([<<"a">>], names(Selected)).

select_excludes_peers_absent_from_index_test() ->
    Peers = [peer(<<"a">>, <<"h1">>, 1), peer(<<"unknown">>, <<"h2">>, 2)],
    Index = #{<<"a">> => [1.0, 0.0]},
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => Index, k => 5}),
    ?assertEqual([<<"a">>], names(Selected)).

%%====================================================================
%% select/2 — media-bank filters are always unioned in
%%====================================================================

select_always_unions_media_filters_test() ->
    Peers = [peer(<<"a">>, <<"h1">>, 1),
             peer(<<"openverse_filter">>, <<"hm">>, 9)],
    %% "openverse_filter" has no index entry (not yet embedded) and would
    %% never be scored/selected on semantics alone — K=1 keeps only "a".
    Index = #{<<"a">> => [1.0, 0.0]},
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => Index, k => 1}),
    ?assertEqual([<<"a">>, <<"openverse_filter">>], names(Selected)).

select_does_not_duplicate_an_already_selected_media_filter_test() ->
    Peers = [peer(<<"openverse_filter">>, <<"hm">>, 9)],
    Index = #{<<"openverse_filter">> => [1.0, 0.0]},
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => Index, k => 5}),
    ?assertEqual([<<"openverse_filter">>], names(Selected)).

select_media_filter_without_query_port_is_not_added_test() ->
    Peers = [peer(<<"a">>, <<"h1">>, 1),
             maps:remove(query_port,
                          peer(<<"sepiasearch_filter">>, <<"hm">>, 9))],
    Index = #{<<"a">> => [1.0, 0.0]},
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => Index, k => 5}),
    ?assertEqual([<<"a">>], names(Selected)).

%%====================================================================
%% select/2 — empty-index fallback shape
%%====================================================================

select_empty_index_and_no_media_peers_returns_empty_test() ->
    %% This is the case `agent_router:run/1' turns into `skip', so
    %% `emquest_handler' falls back to hash-cosine peers_for_query/2.
    Peers = [peer(<<"a">>, <<"h1">>, 1)],
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => #{}, k => 5}),
    ?assertEqual([], Selected).

select_empty_index_still_keeps_live_media_peers_test() ->
    Peers = [peer(<<"nasa_images_filter">>, <<"hm">>, 9)],
    Selected = agent_router:select([1.0, 0.0],
        #{peers => Peers, index => #{}, k => 5}),
    ?assertEqual([<<"nasa_images_filter">>], names(Selected)).

select_no_peers_returns_empty_test() ->
    ?assertEqual([], agent_router:select([1.0, 0.0],
        #{peers => [], index => #{}, k => 5})).
