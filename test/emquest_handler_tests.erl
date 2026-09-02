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

sanitize_passes_text_through_unescaped_test() ->
    In  = #{<<"properties">> => #{<<"title">> => <<"AT&T <b>x</b>">>,
                                  <<"resume">> => <<"a & b < c">>}},
    Out = emquest_handler:normalise_item(In),
    ?assertEqual(<<"AT&T <b>x</b>">>, maps:get(<<"label">>, Out)),
    ?assertEqual(<<"a & b < c">>, maps:get(<<"value">>, Out)).

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

security_headers_app_has_unsafe_hashes_test() ->
    CSP = maps:get(<<"content-security-policy">>,
                   emquest_handler:security_headers(<<"text/html">>, emquest_handler:app_script_extra())),
    ?assertNotEqual(nomatch, binary:match(CSP, <<"'unsafe-hashes'">>)),
    ?assertNotEqual(nomatch, binary:match(CSP, <<"sha256-">>)).

internal_gate_default_off_test() ->
    application:unset_env(emquest, expose_internal),
    ?assertEqual(false, emquest_handler:internal_exposed()).

internal_gate_on_test() ->
    application:set_env(emquest, expose_internal, true),
    ?assertEqual(true, emquest_handler:internal_exposed()),
    application:unset_env(emquest, expose_internal).

client_ip_prefers_cf_header_test() ->
    Req = #{headers => #{<<"cf-connecting-ip">> => <<"9.9.9.9">>},
            peer => {{1,2,3,4}, 5555}},
    ?assertEqual(<<"9.9.9.9">>, emquest_handler:client_ip(Req)).

client_ip_falls_back_to_peer_test() ->
    Req = #{headers => #{}, peer => {{1,2,3,4}, 5555}},
    ?assertEqual(<<"1.2.3.4">>, emquest_handler:client_ip(Req)).

cap_utf8_no_split_test() ->
    %% 200 CJK chars = 600 bytes; capping value at 2048 is fine, but cap label at 256.
    %% unicode:characters_to_binary/1 (not list_to_binary/1, which only accepts
    %% byte values 0-255) UTF-8-encodes the 200 duplicated codepoints.
    Label = unicode:characters_to_binary(lists:duplicate(200, "水")), %% 600 bytes
    In  = #{<<"properties">> => #{<<"title">> => Label}},
    Out = emquest_handler:normalise_item(In),
    L   = maps:get(<<"label">>, Out),
    ?assert(byte_size(L) =< 256),
    %% result must be valid UTF-8 (round-trips) — would fail if a codepoint was split
    ?assertMatch(Bin when is_binary(Bin), unicode:characters_to_binary(L, utf8, utf8)),
    %% and it must JSON-encode without crashing
    ?assertMatch(Enc when is_binary(Enc) orelse is_list(Enc), json:encode(#{<<"l">> => L})).

response_ok_accepts_valid_signature_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Id = em_pop_crypto:id_of(Pub),
    catch em_pop_store:close(),
    Dir = "/tmp/emq_resp_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(Dir ++ "/x"),
    {ok, _} = em_pop_store:open(Dir ++ "/s.dets"),
    em_pop_store:put_pubkey(Id, Pub),
    Items = [#{<<"url">> => <<"u">>, <<"title">> => <<"t">>, <<"resume">> => <<"r">>}],
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_response(Items), Priv),
    RespMap = #{<<"results">> => Items,
                <<"signer_id">> => base64:encode(Id),
                <<"signature">> => base64:encode(Sig)},
    ?assert(emquest_handler:response_ok(RespMap, Items)),
    %% tampered items -> reject
    Tampered = [#{<<"url">> => <<"EVIL">>, <<"title">> => <<"t">>, <<"resume">> => <<"r">>}],
    ?assertNot(emquest_handler:response_ok(RespMap, Tampered)),
    em_pop_store:close(), file:delete(Dir ++ "/s.dets").

response_ok_unsigned_tolerated_by_default_test() ->
    application:unset_env(emquest, require_signatures),
    ?assert(emquest_handler:response_ok(#{<<"results">> => []}, [])).

response_ok_unsigned_rejected_when_required_test() ->
    application:set_env(emquest, require_signatures, true),
    ?assertNot(emquest_handler:response_ok(#{<<"results">> => []}, [])),
    application:unset_env(emquest, require_signatures).
