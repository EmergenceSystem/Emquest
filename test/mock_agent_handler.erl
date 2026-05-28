-module(mock_agent_handler).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, #{results := Results} = State) ->
    Body = iolist_to_binary(json:encode(#{<<"results">> => Results})),
    Req  = cowboy_req:reply(200,
               #{<<"content-type">> => <<"application/json">>},
               Body, Req0),
    {ok, Req, State}.
