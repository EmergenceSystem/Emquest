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

mapped_ipv6_blocked_test() ->
    %% ::ffff:127.0.0.1 and ::ffff:169.254.169.254
    ?assertEqual(true, emquest_safeurl:is_blocked_ip({0,0,0,0,0,16#ffff,16#7f00,16#0001})),
    ?assertEqual(true, emquest_safeurl:is_blocked_ip({0,0,0,0,0,16#ffff,16#a9fe,16#a9fe})),
    %% ::ffff:8.8.8.8 stays allowed
    ?assertEqual(false, emquest_safeurl:is_blocked_ip({0,0,0,0,0,16#ffff,16#0808,16#0808})).

nat64_and_compat_blocked_test() ->
    %% 64:ff9b::127.0.0.1
    ?assertEqual(true, emquest_safeurl:is_blocked_ip({16#64,16#ff9b,0,0,0,0,16#7f00,16#0001})),
    %% ::127.0.0.1 (ipv4-compatible)
    ?assertEqual(true, emquest_safeurl:is_blocked_ip({0,0,0,0,0,0,16#7f00,16#0001})).

extra_ipv4_ranges_blocked_test() ->
    ?assertEqual(true, emquest_safeurl:is_blocked_ip({0,1,2,3})),      %% 0.0.0.0/8
    ?assertEqual(true, emquest_safeurl:is_blocked_ip({100,64,0,1})),   %% CGNAT 100.64/10
    ?assertEqual(true, emquest_safeurl:is_blocked_ip({100,127,255,1})).

%% --- safe_post SSRF guard (open-federation: peer-advertised POST targets) ---
%% Exempt hosts (localhost family) stay reachable so the co-located local
%% mesh keeps working; every other private/loopback/metadata target is blocked.

safe_post_blocks_metadata_test() ->
    ?assertMatch({error, blocked_ip},
                 emquest_safeurl:safe_post(<<"http://169.254.169.254/latest/meta-data/">>,
                                           [], "application/json", <<"{}">>,
                                           [{timeout, 2000}])).

safe_post_blocks_rfc1918_test() ->
    ?assertMatch({error, blocked_ip},
                 emquest_safeurl:safe_post(<<"http://10.0.0.5:9201/agent/query">>,
                                           [], "application/json", <<"{}">>,
                                           [{timeout, 2000}])).

safe_post_blocks_bad_scheme_test() ->
    ?assertMatch({error, bad_scheme},
                 emquest_safeurl:safe_post(<<"file:///etc/passwd">>,
                                           [], "application/json", <<"{}">>,
                                           [{timeout, 2000}])).

%% localhost is exempt: the guard must NOT return blocked_ip; the request
%% proceeds and fails at connect time instead (no listener on port 9).
safe_post_allows_exempt_localhost_test() ->
    inets:start(),
    R = emquest_safeurl:safe_post(<<"http://127.0.0.1:9/agent/query">>,
                                  [], "application/json", <<"{}">>,
                                  [{timeout, 1000}]),
    ?assertNotMatch({error, blocked_ip}, R),
    ?assertNotMatch({error, bad_scheme}, R).

%% check/2 lets callers pass an explicit exempt-host allow-list.
check2_exempts_listed_host_test() ->
    ?assertEqual(ok, emquest_safeurl:check(<<"http://127.0.0.1:9/x">>,
                                           [<<"127.0.0.1">>])),
    ?assertMatch({error, blocked_ip},
                 emquest_safeurl:check(<<"http://10.0.0.1/x">>, [<<"127.0.0.1">>])),
    %% exemption never bypasses the scheme allow-list
    ?assertMatch({error, bad_scheme},
                 emquest_safeurl:check(<<"file:///x">>, [<<"127.0.0.1">>])).
