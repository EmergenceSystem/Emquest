%%%-------------------------------------------------------------------
%%% @doc Emquest top-level supervisor.
%%%
%%% Starts the Cowboy HTTP listener when HTTP mode is enabled and
%%% registers the URL routing table. Runs with a `one_for_one'
%%% strategy — the supervisor itself has no child workers beyond
%%% the Cowboy listener, which is managed by Ranch internally.
%%%
%%% === Routing table ===
%%%
%%% ```
%%% GET  /                → emquest_handler (serves index.html)
%%% POST /query           → emquest_handler (SSE pipeline)
%%% GET  /drift           → emquest_handler (serves drift.html)
%%% GET  /preview         → emquest_handler (URL description proxy)
%%% GET  /network         → emquest_handler (serves network.html)
%%% GET  /network/peers   → emquest_handler (JSON peer list)
%%% GET  /favicon.ico     → cowboy_static   (priv/static/favicon.ico)
%%% GET  /static/[...]    → cowboy_static   (priv/static/)
%%% '''
%%%
%%% === Modes ===
%%%
%%% Full mode (HTTP + CLI):
%%% ```
%%% rebar3 shell
%%% '''
%%%
%%% CLI only (no HTTP server):
%%% ```
%%% EMQUEST_HTTP=false rebar3 shell
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%% @doc Start the top-level supervisor.
%% @end
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Initialise the supervisor.
%%
%% In HTTP mode, compiles the Cowboy routing table and starts the
%% TCP listener on the configured port (default: 8079).
%% In CLI-only mode, returns an empty child list.
%% @end
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    case http_enabled() of
        true ->
            Port     = get_port(),
            Dispatch = cowboy_router:compile([
                {'_', [
                    {"/",               emquest_handler, index},
                    {"/query",          emquest_handler, query},
                    {"/media",          emquest_handler, media},
                    {"/media/prepare/:id", emquest_handler, media_prepare},
                    {"/drift",          emquest_handler, drift},
                    {"/preview",        emquest_handler, preview},
                    {"/network",        emquest_handler, network},
                    {"/network/peers",  emquest_handler, network_peers},
                    {"/favicon.ico",    cowboy_static,   {priv_file, emquest, "static/favicon.ico"}},
                    {"/static/[...]",   cowboy_static,   {priv_dir,  emquest, "static"}}
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
    PopChild = #{
        id       => emquest_pop,
        start    => {emquest_pop, start_link, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [emquest_pop]
    },
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [PopChild]}}.

%%====================================================================
%% Internal
%%====================================================================

%% @private
%% @doc Returns `true' if HTTP mode is enabled.
%%
%% Mirrors {@link emquest_app:http_enabled/0}. Duplicated here to
%% avoid a cross-module call during supervisor `init/1'.
%% @end
-spec http_enabled() -> boolean().
http_enabled() ->
    case os:getenv("EMQUEST_HTTP") of
        "false" -> false;
        "0"     -> false;
        _       ->
            application:get_env(emquest, http, true)
    end.

%% @private
%% @doc Returns the configured HTTP port, defaulting to 8079.
%% @end
-spec get_port() -> inet:port_number().
get_port() ->
    case application:get_env(emquest, port) of
        {ok, P} -> P;
        _       -> 8079
    end.
