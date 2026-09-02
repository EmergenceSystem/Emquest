%%%-------------------------------------------------------------------
%%% @doc DETS-backed persistence for em_pop reputation: per-peer trust
%%% and a ban list. Survives node restart so a banned abuser cannot
%%% return fresh and a peer's earned/lost trust is not reset.
%%%
%%% One named DETS table, two key shapes:
%%%   {trust, Id} => {Trust :: float(), LastSeen :: integer()}
%%%   {ban,   Id} => {Reason :: binary(), Ts :: integer()}
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_store).
-export([open/1, close/0, put_trust/3, get_trust/1, all_trust/0,
         ban/2, unban/1, is_banned/1, all_bans/0,
         put_pubkey/2, get_pubkey/1]).

-define(TAB, em_pop_store).

-spec open(file:filename()) -> {ok, atom()} | {error, term()}.
open(File) ->
    dets:open_file(?TAB, [{file, File}, {type, set}, {auto_save, 5000}]).

-spec close() -> ok.
close() -> case dets:info(?TAB) of undefined -> ok; _ -> dets:close(?TAB) end.

-spec put_trust(binary(), float(), integer()) -> ok.
put_trust(Id, Trust, LastSeen) ->
    dets:insert(?TAB, {{trust, Id}, {Trust, LastSeen}}).

-spec get_trust(binary()) -> {float(), integer()} | undefined.
get_trust(Id) ->
    case dets:lookup(?TAB, {trust, Id}) of
        [{_, V}] -> V;
        []       -> undefined
    end.

-spec all_trust() -> #{binary() => float()}.
all_trust() ->
    dets:foldl(fun({{trust, Id}, {T, _}}, Acc) -> Acc#{Id => T};
                  (_, Acc) -> Acc end, #{}, ?TAB).

-spec ban(binary(), binary()) -> ok.
ban(Id, Reason) ->
    dets:insert(?TAB, {{ban, Id}, {Reason, erlang:system_time(second)}}).

-spec unban(binary()) -> ok.
unban(Id) -> dets:delete(?TAB, {ban, Id}).

-spec is_banned(binary()) -> boolean().
is_banned(Id) -> dets:member(?TAB, {ban, Id}).

-spec all_bans() -> #{binary() => {binary(), integer()}}.
all_bans() ->
    dets:foldl(fun({{ban, Id}, V}, Acc) -> Acc#{Id => V};
                  (_, Acc) -> Acc end, #{}, ?TAB).

-spec put_pubkey(binary(), binary()) -> ok.
put_pubkey(Id, Pub) -> dets:insert(?TAB, {{pubkey, Id}, Pub}).

-spec get_pubkey(binary()) -> binary() | undefined.
get_pubkey(Id) ->
    case dets:lookup(?TAB, {pubkey, Id}) of
        [{_, Pub}] -> Pub;
        []         -> undefined
    end.
