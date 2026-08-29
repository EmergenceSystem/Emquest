-module(emquest_handler_tests).
-include_lib("eunit/include/eunit.hrl").

parse_stt_text_extracts_text_test() ->
    JSON = <<"{\"text\":\"  bonjour le monde \"}">>,
    ?assertEqual(<<"bonjour le monde">>, emquest_handler:parse_stt_text(JSON)).

parse_stt_text_empty_on_garbage_test() ->
    ?assertEqual(<<>>, emquest_handler:parse_stt_text(<<"not json">>)).

normalise_item_media_passthrough_test() ->
    Raw = #{<<"properties">> => #{<<"media_type">> => <<"image">>,
                                  <<"thumbnail">>  => <<"http://x/t.jpg">>,
                                  <<"media_url">>  => <<"http://x/f.jpg">>,
                                  <<"title">>      => <<"Cat">>,
                                  <<"license">>    => <<"CC BY 2.0">>,
                                  <<"url">>        => <<"http://x/page">>}},
    Item = emquest_handler:normalise_item(Raw),
    ?assertEqual(<<"image">>,        maps:get(<<"media_type">>, Item)),
    ?assertEqual(<<"http://x/t.jpg">>, maps:get(<<"thumbnail">>, Item)),
    ?assertEqual(<<"http://x/f.jpg">>, maps:get(<<"media_url">>, Item)),
    ?assertEqual(<<"CC BY 2.0">>,    maps:get(<<"license">>, Item)),
    ?assertEqual(<<"Cat">>,          maps:get(<<"label">>, Item)).

normalise_item_non_media_unchanged_test() ->
    Raw  = #{<<"properties">> => #{<<"url">> => <<"http://x">>, <<"title">> => <<"T">>}},
    Item = emquest_handler:normalise_item(Raw),
    ?assertEqual(false, maps:is_key(<<"media_type">>, Item)),
    ?assertEqual(<<"http://x">>, maps:get(<<"url">>, Item)).
