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

sanitize_escapes_html_in_label_test() ->
    In  = #{<<"properties">> => #{<<"title">> => <<"<script>alert(1)</script>">>,
                                  <<"resume">> => <<"a & b < c">>}},
    Out = emquest_handler:normalise_item(In),
    ?assertEqual(<<"&lt;script&gt;alert(1)&lt;/script&gt;">>, maps:get(<<"label">>, Out)),
    ?assertEqual(<<"a &amp; b &lt; c">>, maps:get(<<"value">>, Out)).

sanitize_drops_javascript_url_test() ->
    In  = #{<<"properties">> => #{<<"title">> => <<"x">>,
                                  <<"url">>   => <<"javascript:alert(1)">>}},
    Out = emquest_handler:normalise_item(In),
    ?assertEqual(error, maps:find(<<"url">>, Out)).

sanitize_keeps_http_url_test() ->
    In  = #{<<"properties">> => #{<<"title">> => <<"x">>,
                                  <<"url">>   => <<"https://example.com/p">>}},
    Out = emquest_handler:normalise_item(In),
    ?assertEqual(<<"https://example.com/p">>, maps:get(<<"url">>, Out)).

sanitize_drops_bad_media_url_test() ->
    In  = #{<<"properties">> => #{<<"title">> => <<"x">>,
                                  <<"media_type">> => <<"image">>,
                                  <<"media_url">>  => <<"data:image/png;base64,xxx">>,
                                  <<"thumbnail">>  => <<"https://ok.example/t.png">>}},
    Out = emquest_handler:normalise_item(In),
    ?assertEqual(error, maps:find(<<"media_url">>, Out)),
    ?assertEqual(<<"https://ok.example/t.png">>, maps:get(<<"thumbnail">>, Out)).

security_headers_present_test() ->
    H = emquest_handler:security_headers(<<"text/html">>),
    ?assertEqual(<<"text/html">>, maps:get(<<"content-type">>, H)),
    CSP = maps:get(<<"content-security-policy">>, H),
    ?assertNotEqual(nomatch, binary:match(CSP, <<"default-src 'self'">>)),
    ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, H)),
    ?assertEqual(<<"DENY">>,    maps:get(<<"x-frame-options">>, H)).
