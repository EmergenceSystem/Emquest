-module(emquest_admin_tests).
-include_lib("eunit/include/eunit.hrl").

tok_hash(T) -> string:lowercase(binary:encode_hex(crypto:hash(sha256, T))).

setup() ->
    Raw = <<"secret-token-abc">>,
    application:set_env(emquest, admin_tokens, #{tok_hash(Raw) => <<"alice">>}),
    application:unset_env(emquest, admin_ips),
    Raw.
cleanup(_) ->
    application:unset_env(emquest, admin_tokens),
    application:unset_env(emquest, admin_ips),
    ok.

valid_token_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Raw) ->
        [?_assertEqual({ok, <<"alice">>}, emquest_admin:authenticate(Raw, <<"9.9.9.9">>))]
    end}.

bad_token_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_Raw) ->
        [?_assertMatch({error, _}, emquest_admin:authenticate(<<"wrong">>, <<"9.9.9.9">>)),
         ?_assertMatch({error, _}, emquest_admin:authenticate(undefined, <<"9.9.9.9">>))]
    end}.

ip_allowlist_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Raw) ->
        application:set_env(emquest, admin_ips, [<<"1.2.3.4">>]),
        [?_assertEqual({ok, <<"alice">>}, emquest_admin:authenticate(Raw, <<"1.2.3.4">>)),
         ?_assertMatch({error, _}, emquest_admin:authenticate(Raw, <<"9.9.9.9">>))]
    end}.

audit_writes_line_test() ->
    F = "/tmp/emq_audit_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".log",
    application:set_env(emquest, admin_audit_log, F),
    ok = emquest_admin:audit(<<"alice">>, <<"ban">>, <<"peer123">>),
    {ok, Bin} = file:read_file(F),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"alice">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"ban">>)),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"peer123">>)),
    application:unset_env(emquest, admin_audit_log),
    file:delete(F).
