-module(emquest_admin_root_tests).
-include_lib("eunit/include/eunit.hrl").

root_detection_test() ->
    application:set_env(emquest, root_pubkeys, [<<"AAAA">>, <<"BBBB">>]),
    ?assert(emquest_handler:is_root_pubkey(<<"AAAA">>)),
    ?assertNot(emquest_handler:is_root_pubkey(<<"CCCC">>)),
    ?assertNot(emquest_handler:is_root_pubkey(undefined)),
    application:unset_env(emquest, root_pubkeys).

peer_json_verified_test() ->
    application:set_env(emquest, root_pubkeys, [base64:encode(<<1:256>>)]),
    Jv = emquest_handler:peer_admin_json(#{name => <<"v">>, trust => 0.5,
                                           query_port => 9101, pubkey => <<1:256>>, role => hub}),
    ?assertEqual(true, maps:get(<<"verified">>, Jv)),
    ?assertEqual(true, maps:get(<<"root">>, Jv)),
    Ju = emquest_handler:peer_admin_json(#{name => <<"u">>, trust => 0.5, query_port => 9101}),
    ?assertEqual(false, maps:get(<<"verified">>, Ju)),
    ?assertEqual(false, maps:get(<<"root">>, Ju)),
    application:unset_env(emquest, root_pubkeys).
