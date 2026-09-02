-module(em_pop_node_store_tests).
-include_lib("eunit/include/eunit.hrl").

start_node(File) ->
    Vec = <<0,0,0,0>>,
    {ok, Pid} = em_pop_node:start_link(#{port => 0, vector => Vec,
                                         gossip_interval => 0, seeds => [],
                                         state_file => File}),
    Pid.

setup() ->
    Dir  = "/tmp/em_pop_node_store_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok   = filelib:ensure_dir(Dir ++ "/x"),
    File = Dir ++ "/s.dets",
    {File, start_node(File)}.

cleanup({File, Pid}) ->
    catch gen_server:stop(Pid),
    catch em_pop_store:close(),
    catch file:delete(File),
    ok.

ban_unban_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_File, Pid}) ->
        ?_test(begin
            ok = em_pop_node:ban(Pid, <<"evil">>, <<"spam">>),
            ?assertEqual(true, em_pop_node:is_banned(Pid, <<"evil">>)),
            ok = em_pop_node:unban(Pid, <<"evil">>),
            ?assertEqual(false, em_pop_node:is_banned(Pid, <<"evil">>))
        end)
    end}.

set_trust_persists_test() ->
    Dir  = "/tmp/em_pop_node_persist_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok   = filelib:ensure_dir(Dir ++ "/x"),
    File = Dir ++ "/s.dets",
    P1 = start_node(File),
    ok = em_pop_node:ban(P1, <<"b">>, <<"r">>),
    gen_server:stop(P1),
    em_pop_store:close(),
    P2 = start_node(File),
    ?assertEqual(true, em_pop_node:is_banned(P2, <<"b">>)),
    gen_server:stop(P2),
    em_pop_store:close(),
    file:delete(File).
