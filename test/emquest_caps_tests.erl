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

reports_count_and_top_test() ->
    A = <<"aaa_test_sid">>, B = <<"bbb_test_sid">>,
    emquest_reports:report(A, <<"spam">>, <<"http://x/1">>),
    emquest_reports:report(A, <<"spam">>, <<"http://x/2">>),
    emquest_reports:report(B, <<"nsfw">>, <<"http://y/1">>),
    ?assertEqual(2, maps:get(count, emquest_reports:get(A))),
    ?assertEqual(1, maps:get(count, emquest_reports:get(B))),
    Top = emquest_reports:top(10),
    First = hd([S || #{signer_id := S} = M <- Top, maps:get(count, M) >= 2]),
    ?assertEqual(A, First),
    catch dets:delete(emquest_reports, A),
    catch dets:delete(emquest_reports, B).
