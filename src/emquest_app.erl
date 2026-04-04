%%%-------------------------------------------------------------------
%%% @doc Emquest OTP application callback module.
%%%
%%% Starts the Emquest application within the Emergence distributed
%%% discovery network. Conditionally boots the Cowboy HTTP server
%%% depending on the runtime configuration.
%%%
%%% `inets' is always started because both {@link emquest_cli} and
%%% {@link queen} use `httpc' for outbound HTTP requests to em_disco
%%% nodes and LLM providers.
%%%
%%% === HTTP mode control ===
%%%
%%% HTTP is enabled by default. It can be disabled via:
%%% <ul>
%%%   <li>Environment variable: `EMQUEST_HTTP=false' or `EMQUEST_HTTP=0'</li>
%%%   <li>Application env: `{http, false}' in sys.config</li>
%%% </ul>
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_app).
-behaviour(application).

-export([start/2, stop/1]).

%% @doc Start the Emquest application.
%%
%% Installs a primary logger filter to suppress OTP progress reports,
%% ensures `inets' is running, then conditionally starts `cowboy'
%% before handing off to {@link emquest_sup}.
%% @end
-spec start(application:start_type(), term()) ->
    {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    logger:add_primary_filter(no_progress,
        {fun logger_filters:progress/2, stop}),
    %% Only ensure cowboy is started when HTTP is needed.
    %% inets is always started (used by emquest_cli via em_disco).
    application:ensure_all_started(inets),
    case http_enabled() of
        true  -> application:ensure_all_started(cowboy);
        false -> ok
    end,
    emquest_sup:start_link().

%% @doc Stop the Emquest application.
%%
%% Stops the Cowboy listener if HTTP mode was active.
%% @end
-spec stop(term()) -> ok.
stop(_State) ->
    case http_enabled() of
        true  -> catch cowboy:stop_listener(emquest_listener);
        false -> ok
    end.

%% @private
%% @doc Returns `true' if HTTP mode is enabled.
%%
%% Checks the `EMQUEST_HTTP' environment variable first, then falls
%% back to the `{http, boolean()}' application environment key.
%% Defaults to `true'.
%% @end
-spec http_enabled() -> boolean().
http_enabled() ->
    case os:getenv("EMQUEST_HTTP") of
        "false" -> false;
        "0"     -> false;
        _       -> application:get_env(emquest, http, true)
    end.
