-module(emquest_ratelimit_tests).
-include_lib("eunit/include/eunit.hrl").

setup()    -> emquest_ratelimit:init(), ok.
cleanup(_) -> catch ets:delete(emquest_ratelimit), ok.

bucket_allows_then_blocks_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        Key = <<"1.2.3.4">>,
        Allowed = [emquest_ratelimit:allow(Key, 3, 60) || _ <- lists:seq(1,3)],
        Blocked = emquest_ratelimit:allow(Key, 3, 60),
        [?_assertEqual([true,true,true], Allowed),
         ?_assertEqual(false, Blocked)]
    end}.

separate_keys_independent_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        ?_assert(emquest_ratelimit:allow(<<"a">>, 1, 60)
                 andalso emquest_ratelimit:allow(<<"b">>, 1, 60))
    end}.
