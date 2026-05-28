-module(emquest_pop_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([starts_successfully/1,
         peers_for_query_returns_empty_list_when_no_peers/1,
         peers_for_query_filters_out_no_query_port/1]).

all() ->
    [starts_successfully,
     peers_for_query_returns_empty_list_when_no_peers,
     peers_for_query_filters_out_no_query_port].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) -> ok.

%% emquest_pop starts an em_pop node and can be shut down cleanly.
starts_successfully(_Config) ->
    %% Use an unregistered start to avoid conflicting with a running Emquest.
    {ok, Pid} = gen_server:start_link(emquest_pop,
                                       #{pop_port => 19500, seeds => []},
                                       []),
    true = is_pid(Pid),
    gen_server:stop(Pid),
    ok.

%% When there are no peers, peers_for_query returns [].
peers_for_query_returns_empty_list_when_no_peers(_Config) ->
    {ok, Pid} = gen_server:start_link(emquest_pop,
                                       #{pop_port => 19501, seeds => []},
                                       []),
    Vec    = em_filter_vec:from_capabilities([<<"rss">>]),
    []     = gen_server:call(Pid, {peers_for_query, Vec, 5}),
    gen_server:stop(Pid),
    ok.

%% peers_for_query returns only peers that have a non-undefined query_port.
peers_for_query_filters_out_no_query_port(_Config) ->
    %% Start an emquest_pop instance.
    {ok, PopPid} = gen_server:start_link(emquest_pop,
                                          #{pop_port => 19502, seeds => []},
                                          []),
    Vec = em_filter_vec:from_capabilities([<<"rss">>]),

    %% Start a peer agent WITH a query_port and connect it to our pop node.
    {ok, AgentPid} = em_pop_node:start_link(#{
        port            => 19503,
        query_port      => 19504,
        vector          => Vec,
        gossip_interval => 0
    }),
    %% Manually inject the agent as a peer of our pop node.
    #{node := Node} = sys:get_state(PopPid),
    ok = em_pop_node:add_peer(Node, "127.0.0.1", 19503),

    %% peers_for_query must return the agent (has query_port).
    Results = gen_server:call(PopPid, {peers_for_query, Vec, 5}),
    1 = length(Results),
    {PeerMap, _Score} = hd(Results),
    19504 = maps:get(query_port, PeerMap),

    gen_server:stop(PopPid),
    unlink(AgentPid),
    exit(AgentPid, shutdown),
    ok.
