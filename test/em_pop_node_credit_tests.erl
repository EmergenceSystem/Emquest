-module(em_pop_node_credit_tests).
-include_lib("eunit/include/eunit.hrl").

%% Non-zero 1-dim capability vector (float 1.0) — a zero vector makes kvex:add
%% fail on normalisation, so use a real one.
-define(VEC, <<0,0,128,63>>).

start_node() ->
    {ok, Pid} = em_pop_node:start_link(#{port => 0, vector => ?VEC,
                                         gossip_interval => 0, seeds => []}),
    Pid.

%% Seed one peer into the node by delivering a gossip payload whose self-
%% description is that peer; handle_gossip upserts it at TRUST_INIT.
seed_peer(Pid, PeerId) ->
    Payload = #{<<"id">>         => base64:encode(PeerId),
                <<"host">>       => <<"127.0.0.1">>,
                <<"port">>       => 19999,
                <<"query_port">> => null,
                <<"name">>       => <<"t">>,
                <<"vector">>     => base64:encode(?VEC),
                <<"peers">>      => []},
    {ok, _} = em_pop_node:handle_gossip(Pid, Payload),
    ok.

credit_raises_penalize_lowers_test() ->
    Pid = start_node(),
    Id  = <<1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16>>,
    ok  = seed_peer(Pid, Id),
    T0  = em_pop_node:get_trust(Pid, Id),
    ok  = em_pop_node:credit(Pid, Id),
    ok  = em_pop_node:credit(Pid, Id),
    timer:sleep(50),
    T1  = em_pop_node:get_trust(Pid, Id),
    ?assert(T1 > T0),
    ok  = em_pop_node:penalize(Pid, Id),
    timer:sleep(50),
    T2  = em_pop_node:get_trust(Pid, Id),
    ?assert(T2 < T1),
    gen_server:stop(Pid).

credit_unknown_id_is_safe_test() ->
    Pid = start_node(),
    ok  = em_pop_node:credit(Pid, <<0:128>>),
    ok  = em_pop_node:penalize(Pid, <<0:128>>),
    timer:sleep(30),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid).

credit_caps_at_max_test() ->
    Pid = start_node(),
    Id  = <<16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1>>,
    ok  = seed_peer(Pid, Id),
    [em_pop_node:credit(Pid, Id) || _ <- lists:seq(1, 30)],
    timer:sleep(80),
    ?assert(em_pop_node:get_trust(Pid, Id) =< 1.0),
    gen_server:stop(Pid).
