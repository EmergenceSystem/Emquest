-module(emquest_safeurl_tests).
-include_lib("eunit/include/eunit.hrl").

scheme_allowed_test() ->
    ?assertEqual(ok, emquest_safeurl:check_scheme(<<"http://example.com/a.jpg">>)),
    ?assertEqual(ok, emquest_safeurl:check_scheme(<<"https://example.com/a.jpg">>)).

scheme_rejected_test() ->
    ?assertMatch({error, bad_scheme}, emquest_safeurl:check_scheme(<<"javascript:alert(1)">>)),
    ?assertMatch({error, bad_scheme}, emquest_safeurl:check_scheme(<<"data:text/html,x">>)),
    ?assertMatch({error, bad_scheme}, emquest_safeurl:check_scheme(<<"file:///etc/passwd">>)),
    ?assertMatch({error, bad_scheme}, emquest_safeurl:check_scheme(<<"ftp://x/y">>)).

private_ipv4_blocked_test() ->
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({127,0,0,1})),
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({10,0,0,5})),
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({172,16,3,4})),
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({192,168,1,94})),
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({169,254,169,254})),
    ?assertEqual(false, emquest_safeurl:is_blocked_ip({93,184,216,34})).

private_ipv6_blocked_test() ->
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({0,0,0,0,0,0,0,1})),
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({16#fe80,0,0,0,0,0,0,1})),
    ?assertEqual(true,  emquest_safeurl:is_blocked_ip({16#fd00,0,0,0,0,0,0,1})),
    ?assertEqual(false, emquest_safeurl:is_blocked_ip({16#2606,16#2800,16#220,1,16#248,16#1893,16#25c8,16#1946})).

guard_rejects_metadata_url_test() ->
    ?assertMatch({error, blocked_ip},
                 emquest_safeurl:safe_get(<<"http://169.254.169.254/latest/meta-data/">>, [], [{timeout, 2000}])).

guard_rejects_localhost_test() ->
    ?assertMatch({error, blocked_ip},
                 emquest_safeurl:safe_get(<<"http://127.0.0.1:8300/health">>, [], [{timeout, 2000}])).
