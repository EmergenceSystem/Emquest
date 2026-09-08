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
