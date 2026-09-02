%%%-------------------------------------------------------------------
%%% @doc Per-key token-bucket rate limiter backed by a public ETS table.
%%%
%%% `allow(Key, Capacity, RefillSeconds)' returns `true' if a token is
%%% available for `Key' (refilling `Capacity' tokens per `RefillSeconds'
%%% window), `false' otherwise.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_ratelimit).
-export([init/0, allow/3]).

-define(TAB, ?MODULE).

%% @doc Create the ETS table if absent. Idempotent; call at app start.
-spec init() -> ok.
init() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [named_table, public, set, {write_concurrency, true}]),
            ok;
        _ -> ok
    end.

%% @doc True if a token is available for Key under Capacity/RefillSeconds.
-spec allow(binary(), pos_integer(), pos_integer()) -> boolean().
allow(Key, Capacity, RefillSeconds) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(?TAB, Key) of
        [] ->
            ets:insert(?TAB, {Key, Capacity - 1, Now}),
            true;
        [{Key, Tokens, Last}] ->
            Refill = ((Now - Last) * Capacity) div RefillSeconds,
            Avail  = min(Capacity, Tokens + max(0, Refill)),
            NewLast = case Refill > 0 of true -> Now; false -> Last end,
            case Avail >= 1 of
                true  -> ets:insert(?TAB, {Key, Avail - 1, NewLast}), true;
                false -> ets:insert(?TAB, {Key, Avail, NewLast}), false
            end
    end.
