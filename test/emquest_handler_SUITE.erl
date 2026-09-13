-module(emquest_handler_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([fetch_from_agent_returns_items/1,
         fetch_from_agent_bad_response_returns_error/1,
         query_pipeline_completes_without_crash/1]).

all() ->
    [fetch_from_agent_returns_items,
     fetch_from_agent_bad_response_returns_error,
     query_pipeline_completes_without_crash].

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

%% End-to-end /query: boots the real route and posts a query with no
%% em_pop node / hf services running. The whole pipeline must run — query
%% expansion, peer selection (incl. the media-bank union that a missing
%% agent_router:with_media/2 export once crashed), collection, ranking,
%% rerank-skip — and stream a final `reorder' without a 500. This is the
%% wiring guard eunit couldn't provide.
query_pipeline_completes_without_crash(_Config) ->
    %% The rate-limit ETS table is owned by whichever process created it;
    %% create it here (this test process lives for the whole case) so the
    %% /query handler's rate-limit check doesn't hit a missing table.
    emquest_ratelimit:init(),
    Dispatch = cowboy_router:compile([
        {'_', [{"/query", emquest_handler, query}]}
    ]),
    {ok, _} = cowboy:start_clear(q_pipeline_listener,
                                 [{port, 19611}],
                                 #{env => #{dispatch => Dispatch}}),
    try
        %% Unique query so a warm cache never short-circuits the pipeline.
        Q = <<"ct pipeline probe ",
              (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
        Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
        {ok, {{_, 200, _}, _Hdrs, Resp}} =
            httpc:request(post,
                {"http://localhost:19611/query", [], "application/json", Body},
                [{timeout, 30000}], [{body_format, binary}]),
        %% run_pipeline_full always emits a final reorder once it gets past
        %% selection + collection without crashing.
        nomatch =/= binary:match(Resp, <<"\"type\":\"reorder\"">>)
    after
        cowboy:stop_listener(q_pipeline_listener)
    end,
    ok.
