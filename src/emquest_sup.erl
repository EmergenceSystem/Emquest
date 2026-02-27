%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_sup — Top-Level Supervisor
%%%
%%% Starts the Cowboy HTTP listener only when http mode is enabled.
%%%
%%% HTTP is enabled (default) unless:
%%%   - env var  EMQUEST_HTTP=false
%%%   - app env  {http, false} in emquest.app.src
%%%
%%% Usage:
%%%   # Full mode (HTTP + CLI)
%%%   rebar3 shell
%%%
%%%   # CLI only (no HTTP server)
%%%   EMQUEST_HTTP=false rebar3 shell
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    case http_enabled() of
        true ->
            Port     = get_port(),
            Dispatch = cowboy_router:compile([
                {'_', [
                    {"/",             emquest_handler, index},
                    {"/query",        emquest_handler, query},
                    {"/favicon.ico",  cowboy_static,   {priv_file, emquest, "static/favicon.ico"}},
                    {"/static/[...]", cowboy_static,   {priv_dir,  emquest, "static"}}
                ]}
            ]),
            {ok, _} = cowboy:start_clear(emquest_listener,
                [{port, Port}],
                #{env => #{dispatch => Dispatch}}
            ),
            io:format("[emquest] HTTP listening on http://localhost:~p~n", [Port]),
            io:format("[emquest] Shell: emquest_cli:query(\"...\").~n");
        false ->
            io:format("[emquest] HTTP disabled — shell only~n"),
            io:format("[emquest] Shell: emquest_cli:query(\"...\").~n")
    end,
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.

%%====================================================================
%% Internal
%%====================================================================

http_enabled() ->
    case os:getenv("EMQUEST_HTTP") of
        "false" -> false;
        "0"     -> false;
        _       ->
            %% Fall back to app env (default: true)
            application:get_env(emquest, http, true)
    end.

get_port() ->
    case application:get_env(emquest, port) of
        {ok, P} -> P;
        _       -> 8079
    end.
