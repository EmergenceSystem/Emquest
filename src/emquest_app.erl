-module(emquest_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    io:format("Emquest V0.1.0~n"),
    Port = embryo:get_port_from_env("embox_port", 8079),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/", emquest_handler, [index]},
            {"/query", emquest_handler, [query]},
            {"/summarize", emquest_handler, [summarize]},
            {"/static/[...]", cowboy_static, {priv_dir, emquest, "static"}}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(
        emquest_http,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    emquest_sup:start_link().

stop(_State) ->
    ok.
