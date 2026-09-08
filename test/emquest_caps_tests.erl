-module(emquest_caps_tests).
-include_lib("eunit/include/eunit.hrl").

cap_items_truncates_test() ->
    Items = [#{<<"label">> => integer_to_binary(N)} || N <- lists:seq(1, 300)],
    application:set_env(emquest, filter_max_items, 200),
    Capped = emquest_handler:cap_items(Items),
    ?assertEqual(200, length(Capped)),
    ?assertEqual(hd(Items), hd(Capped)).

cap_items_keeps_small_test() ->
    Items = [#{<<"label">> => <<"a">>}, #{<<"label">> => <<"b">>}],
    application:set_env(emquest, filter_max_items, 200),
    ?assertEqual(Items, emquest_handler:cap_items(Items)).

normalise_item_carries_source_test() ->
    I = #{<<"__source_id">> => <<"abc">>, <<"__source">> => <<"reddit_filter">>,
          <<"label">> => <<"x">>},
    N = emquest_handler:normalise_item(I),
    ?assertEqual(<<"abc">>, maps:get(<<"source_id">>, N)),
    ?assertEqual(<<"reddit_filter">>, maps:get(<<"source">>, N)).

normalise_item_source_null_test() ->
    N = emquest_handler:normalise_item(#{<<"label">> => <<"x">>}),
    ?assertEqual(null, maps:get(<<"source_id">>, N)).
