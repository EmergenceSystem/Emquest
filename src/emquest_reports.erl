%%%-------------------------------------------------------------------
%%% @doc DETS-backed user reports against filters (moderation queue).
%%% Key: SignerIdB64 (base64 filter id) => {Count, [Sample]} where a
%%% Sample is #{reason, url, ts}. Lazily opened; persists across restart.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_reports).
-export([open/0, report/3, get/1, top/1]).
-define(TAB, emquest_reports).
-define(MAX_SAMPLES, 20).

-spec open() -> {ok, atom()} | {error, term()}.
open() ->
    Dir  = filename:join(code:priv_dir(emquest), "state"),
    ok   = filelib:ensure_dir(filename:join(Dir, "x")),
    File = filename:join(Dir, "emquest_reports.dets"),
    dets:open_file(?TAB, [{file, File}, {type, set}, {auto_save, 5000}]).

ensure() -> case dets:info(?TAB) of undefined -> open(), ok; _ -> ok end.

-spec report(binary(), binary(), binary()) -> ok.
report(Sid, Reason, Url) when is_binary(Sid) ->
    ensure(),
    {Count, Samples} = case dets:lookup(?TAB, Sid) of
                           [{Sid, C, S}] -> {C, S};
                           _             -> {0, []}
                       end,
    Sample   = #{reason => Reason, url => Url, ts => erlang:system_time(second)},
    Samples2 = lists:sublist([Sample | Samples], ?MAX_SAMPLES),
    dets:insert(?TAB, {Sid, Count + 1, Samples2}),
    ok.

-spec get(binary()) -> map().
get(Sid) ->
    ensure(),
    case dets:lookup(?TAB, Sid) of
        [{Sid, C, S}] -> #{signer_id => Sid, count => C, samples => S};
        _             -> #{signer_id => Sid, count => 0, samples => []}
    end.

-spec top(pos_integer()) -> [map()].
top(N) ->
    ensure(),
    All = dets:foldl(
            fun({Sid, C, S}, Acc) ->
                [#{signer_id => Sid, count => C, samples => S} | Acc]
            end, [], ?TAB),
    lists:sublist(
      lists:sort(fun(A, B) -> maps:get(count, A) >= maps:get(count, B) end, All),
      N).
