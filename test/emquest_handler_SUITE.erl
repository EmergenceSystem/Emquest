-module(emquest_handler_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([fetch_from_agent_returns_items/1,
         fetch_from_agent_bad_response_returns_error/1]).

all() ->
    [fetch_from_agent_returns_items,
     fetch_from_agent_bad_response_returns_error].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) -> ok.

%% fetch_from_agent/2 parses a {"results": [...]} response correctly.
fetch_from_agent_returns_items(_Config) ->
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", mock_agent_handler,
                #{results => [#{<<"url">> => <<"http://example.com">>}]}}]}
    ]),
    {ok, _} = cowboy:start_clear(mock_agent_listener,
                                  [{port, 19600}],
                                  #{env => #{dispatch => Dispatch}}),
    Body = iolist_to_binary(json:encode(#{<<"query">> => <<"test">>})),
    {ok, Items} = emquest_handler:fetch_from_agent(
                      Body, "http://localhost:19600/agent/query"),
    true = is_list(Items),
    true = length(Items) > 0,
    cowboy:stop_listener(mock_agent_listener),
    ok.

%% An unreachable agent returns {error, _}.
fetch_from_agent_bad_response_returns_error(_Config) ->
    Body = iolist_to_binary(json:encode(#{<<"query">> => <<"test">>})),
    {error, _} = emquest_handler:fetch_from_agent(
                     Body, "http://localhost:1/agent/query"),
    ok.
