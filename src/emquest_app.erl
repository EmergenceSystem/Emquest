%%%-------------------------------------------------------------------
%%% @doc emquest_app — OTP Application Entry Point
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Only ensure cowboy is started when HTTP is needed.
    %% inets is always started (used by emquest_cli via em_disco).
    application:ensure_all_started(inets),
    case http_enabled() of
        true  -> application:ensure_all_started(cowboy);
        false -> ok
    end,
    emquest_sup:start_link().

stop(_State) ->
    case http_enabled() of
        true  -> catch cowboy:stop_listener(emquest_listener);
        false -> ok
    end.

http_enabled() ->
    case os:getenv("EMQUEST_HTTP") of
        "false" -> false;
        "0"     -> false;
        _       -> application:get_env(emquest, http, true)
    end.
