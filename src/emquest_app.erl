%%%-------------------------------------------------------------------
%%% @doc emquest_app: HTTP server based on Wade.
%%%-------------------------------------------------------------------
-module(emquest_app).
-behaviour(application).

-export([start/2, stop/1]).
-include_lib("wade/include/wade.hrl").

%% @doc Application entry point.
start(_StartType, _StartArgs) ->
    io:format("Emquest Wade Server starting...~n"),
    Port = get_port(),
    StaticDir = get_static_dir(),

    %% Start Wade server
    case wade:start_link(Port) of
        {ok, _ListenerPid} ->
            io:format("Wade server listening on port ~p~n", [Port]),

            %% Register routes
            wade:route(get, "/", fun emquest_handler:handle_index/1, []),
            wade:route(post, "/query", fun emquest_handler:handle_query/1, []),
            wade:route(post, "/summarize", fun emquest_handler:handle_summarize/1, []),

            %% Register static route if StaticDir is defined
            case StaticDir of
                undefined ->
                    io:format("No static directory configured~n");
                Dir ->
                    io:format("Serving static files from ~p~n", [Dir]),
                    %% FIX: Changed #{} to [] for consistency with other routes
                    wade:route(get, "/static/[path]", fun emquest_handler:serve_static/1, [])
            end,

            emquest_sup:start_link(),
            {ok, self()};
        {error, Reason} ->
            io:format("Failed to start Wade server: ~p~n", [Reason]),
            {error, Reason}
    end.

%% @doc Stop the application.
stop(_State) ->
    ok.

%% @doc Get the port from configuration or use 8079 as default.
get_port() ->
    case application:get_env(emquest_app, port) of
        {ok, P} -> P;
        _ -> 8079
    end.

%% @doc Get the static files directory.
get_static_dir() ->
    case code:priv_dir(emquest) of
        {error, bad_name} ->
            io:format("Static directory not found, static disabled~n"),
            undefined;
        Dir ->
            StaticDir = filename:join([Dir, "static"]),
            case filelib:is_dir(StaticDir) of
                true ->
                    io:format("Static directory: ~p~n", [StaticDir]),
                    StaticDir;
                false ->
                    io:format("Static directory ~p does not exist~n", [StaticDir]),
                    undefined
            end
    end.
