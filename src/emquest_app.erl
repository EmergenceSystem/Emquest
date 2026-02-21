%%%-------------------------------------------------------------------
%%% @doc emquest_app — HTTP server based on Cowboy.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Port = get_port(),
    io:format("[emquest] Starting on port ~p~n", [Port]),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/",           emquest_handler, index},
            {"/query",      emquest_handler, query},
            {"/static/[...]", cowboy_static,
                {priv_dir, emquest, "static"}}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(emquest_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),

    io:format("[emquest] Listening on port ~p~n", [Port]),
    emquest_sup:start_link().

stop(_State) ->
    cowboy:stop_listener(emquest_listener).

get_port() ->
    case application:get_env(emquest, port) of
        {ok, P} -> P;
        _       -> 8079
    end.
