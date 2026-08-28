-module(emquest_handler_tests).
-include_lib("eunit/include/eunit.hrl").

parse_stt_text_extracts_text_test() ->
    JSON = <<"{\"text\":\"  bonjour le monde \"}">>,
    ?assertEqual(<<"bonjour le monde">>, emquest_handler:parse_stt_text(JSON)).

parse_stt_text_empty_on_garbage_test() ->
    ?assertEqual(<<>>, emquest_handler:parse_stt_text(<<"not json">>)).
