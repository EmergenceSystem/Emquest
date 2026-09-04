-module(em_pop_store_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    Dir = "/tmp/em_pop_store_test_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(Dir ++ "/x"),
    File = Dir ++ "/store.dets",
    {ok, _} = em_pop_store:open(File),
    File.

cleanup(File) ->
    catch em_pop_store:close(),
    catch file:delete(File),
    ok.

trust_roundtrip_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        em_pop_store:put_trust(<<"peer1">>, 0.42, 1000),
        [?_assertEqual({0.42, 1000}, em_pop_store:get_trust(<<"peer1">>)),
         ?_assertEqual(undefined, em_pop_store:get_trust(<<"nope">>))]
    end}.

all_trust_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        em_pop_store:put_trust(<<"a">>, 0.1, 1),
        em_pop_store:put_trust(<<"b">>, 0.9, 2),
        M = em_pop_store:all_trust(),
        [?_assertEqual(0.1, maps:get(<<"a">>, M)),
         ?_assertEqual(0.9, maps:get(<<"b">>, M))]
    end}.

ban_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        ?_test(begin
            ?assertEqual(false, em_pop_store:is_banned(<<"x">>)),
            em_pop_store:ban(<<"x">>, <<"spam">>),
            ?assertEqual(true, em_pop_store:is_banned(<<"x">>)),
            ?assert(maps:is_key(<<"x">>, em_pop_store:all_bans())),
            em_pop_store:unban(<<"x">>),
            ?assertEqual(false, em_pop_store:is_banned(<<"x">>))
        end)
    end}.

persists_across_reopen_test() ->
    Dir  = "/tmp/em_pop_store_reopen_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok   = filelib:ensure_dir(Dir ++ "/x"),
    File = Dir ++ "/store.dets",
    {ok, _} = em_pop_store:open(File),
    em_pop_store:put_trust(<<"keep">>, 0.7, 5),
    em_pop_store:ban(<<"bad">>, <<"r">>),
    em_pop_store:close(),
    {ok, _} = em_pop_store:open(File),
    ?assertEqual({0.7, 5}, em_pop_store:get_trust(<<"keep">>)),
    ?assertEqual(true, em_pop_store:is_banned(<<"bad">>)),
    em_pop_store:close(),
    file:delete(File).
