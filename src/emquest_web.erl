-module(emquest_web).

-export([start/0]).

start() ->
    application:ensure_all_started(emquest).
