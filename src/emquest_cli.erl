%%%-------------------------------------------------------------------
%%% @doc Interactive shell client for Emquest.
%%%
%%% Provides a convenience interface for querying the Emergence
%%% network directly from an `rebar3 shell' session.
%%%
%%% A second client alongside the browser: unlike {@link emquest_handler},
%%% which runs the full pipeline server-side, this module calls em_disco
%%% directly — it POSTs the search term to the em_disco HTTP API and
%%% pretty-prints the raw response.
%%%
%%% The target URL is resolved in this order:
%%%   1. `server_url' environment variable
%%%   2. `server_url' key under `[em_disco]' in `emergence.conf'
%%%   3. Default: `http://localhost:8080'
%%%
%%% === Usage ===
%%%
%%% ```
%%% emquest_cli:query("google.com").
%%% emquest_cli:query(<<"what is erlang">>).
%%% '''
%%%
%%% `inets' is started on demand so the function works even when
%%% called before the application is fully booted.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_cli).

-export([query/1, ban/1, unban/1]).

%%--------------------------------------------------------------------
%% @doc Queries em_disco via HTTP and prints results to stdout.
%% Accepts binary or string input.
%% @end
%%--------------------------------------------------------------------
-spec query(binary() | string()) -> ok.
query(Search) when is_list(Search) ->
    query(list_to_binary(Search));
query(Search) when is_binary(Search) ->
    application:ensure_all_started(inets),
    io:format("~n[emquest] querying: ~s~n~n", [Search]),
    Body = iolist_to_binary(json:encode(#{<<"value">> => Search})),
    case post_to_disco(Body) of
        {ok, RespBody} ->
            handle_response(RespBody);
        {error, Reason} ->
            io:format("[emquest] error: ~p~n", [Reason])
    end.

%%--------------------------------------------------------------------
%% @doc Ban a peer by id from the em_pop peer table.
%% Accepts binary or string input.
%% @end
%%--------------------------------------------------------------------
-spec ban(binary() | string()) -> ok.
ban(PeerId) ->
    Id = iolist_to_binary(PeerId),
    case emquest_pop:ban(Id, <<"cli">>) of
        ok ->
            io:format("[emquest] banned ~s~n", [Id]);
        {error, Reason} ->
            io:format("[emquest] ban failed for ~s: ~p~n", [Id, Reason])
    end.

%%--------------------------------------------------------------------
%% @doc Lift a ban on a peer by id.
%% Accepts binary or string input.
%% @end
%%--------------------------------------------------------------------
-spec unban(binary() | string()) -> ok.
unban(PeerId) ->
    Id = iolist_to_binary(PeerId),
    case emquest_pop:unban(Id) of
        ok ->
            io:format("[emquest] unbanned ~s~n", [Id]);
        {error, Reason} ->
            io:format("[emquest] unban failed for ~s: ~p~n", [Id, Reason])
    end.

%%====================================================================
%% HTTP
%%====================================================================

%% @private
%% @doc POST `Body' (JSON) to the disco query endpoint.
%%
%% Returns `{ok, ResponseBody}' on HTTP 200, `{error, Reason}'
%% otherwise. Timeout is 10 seconds.
%% @end
-spec post_to_disco(binary()) -> {ok, binary()} | {error, term()}.
post_to_disco(Body) ->
    Url = disco_url() ++ "/query",
    case httpc:request(post,
                       {Url, [], "application/json", binary_to_list(Body)},
                       [{timeout, 10000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} -> {ok, RespBody};
        {ok, {{_, Code, _}, _, _}}       -> {error, {http, Code}};
        {error, Reason}                  -> {error, Reason}
    end.

%% @private
%% @doc Resolve the em_disco base URL.
%%
%% Checks the `server_url' environment variable first, then reads
%% `emergence.conf', then falls back to `http://localhost:8080'.
%% @end
-spec disco_url() -> string().
disco_url() ->
    case os:getenv("server_url") of
        false ->
            case read_conf_url() of
                undefined -> "http://localhost:8080";
                Url       -> Url
            end;
        Url -> Url
    end.

read_conf_url() ->
    Home = case os:getenv("HOME") of
        false ->
            case os:getenv("APPDATA") of
                false   -> undefined;
                AppData -> filename:join([AppData, "emergence", "emergence.conf"])
            end;
        H ->
            case os:type() of
                {unix, _} -> filename:join([H, ".config", "emergence", "emergence.conf"]);
                _         -> filename:join([H, "AppData", "Roaming", "emergence", "emergence.conf"])
            end
    end,
    case Home of
        undefined -> undefined;
        Path ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    Conf = parse_conf(Bin),
                    case maps:get("server_url", maps:get("em_disco", Conf, #{}), undefined) of
                        undefined -> undefined;
                        Url       -> Url
                    end;
                _ -> undefined
            end
    end.

parse_conf(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    {Map, _} = lists:foldl(fun
        (<<";", _/binary>>, Acc) -> Acc;
        (<<"#", _/binary>>, Acc) -> Acc;
        (<<"[", Rest/binary>>, {M, _}) ->
            Sec = string:trim(binary_to_list(binary:part(Rest, 0, byte_size(Rest)-1))),
            {M#{Sec => #{}}, Sec};
        (Line, {M, Sec}) when Sec =/= "" ->
            case binary:split(Line, <<"=">>) of
                [K, V] ->
                    Key = string:trim(binary_to_list(K)),
                    Val = string:trim(binary_to_list(V)),
                    {M#{Sec => maps:put(Key, Val, maps:get(Sec, M, #{}))}, Sec};
                _ -> {M, Sec}
            end;
        (_, Acc) -> Acc
    end, {#{}, ""}, Lines),
    Map.

%%====================================================================
%% Response
%%====================================================================

handle_response(Body) ->
    try json:decode(Body) of
        #{<<"embryo_list">> := Embryos} when is_list(Embryos) ->
            case Embryos of
                [] -> io:format("  (no results)~n~n");
                _  ->
                    lists:foreach(fun print_embryo/1, Embryos),
                    io:format("[emquest] ~p result(s)~n", [length(Embryos)])
            end;
        _ ->
            io:format("~ts~n", [Body])
    catch
        _:_ -> io:format("~ts~n", [Body])
    end.

print_embryo(Item) ->
    Props  = maps:get(<<"properties">>, Item, Item),
    Type   = maps:get(<<"type">>, Item, <<"result">>),

    Url     = maps:get(<<"url">>,     Props, undefined),
    Title   = maps:get(<<"title">>,   Props,
              maps:get(<<"label">>,   Props,
              maps:get(<<"domain">>,  Props, undefined))),
    Resume  = maps:get(<<"resume">>,  Props,
              maps:get(<<"value">>,   Props, undefined)),
    Ips     = maps:get(<<"ips">>,     Props, undefined),
    Content = maps:get(<<"content">>, Props, undefined),

    io:format("  ── ~s ──~n", [string:uppercase(binary_to_list(Type))]),

    case Title of
        undefined -> ok;
        _         -> io:format("  ~ts~n", [Title])
    end,
    case Url of
        undefined -> ok;
        _         -> io:format("  ~ts~n", [Url])
    end,
    case Ips of
        undefined -> ok;
        _         ->
            IpStrs = [binary_to_list(Ip) || Ip <- Ips, is_binary(Ip)],
            io:format("  IPs: ~s~n", [string:join(IpStrs, ", ")])
    end,
    case Content of
        undefined -> ok;
        _         -> io:format("~ts~n", [Content])
    end,
    case Resume of
        undefined -> ok;
        _         ->
            Wrapped = wrap(binary_to_list(Resume), 72),
            lists:foreach(fun(L) -> io:format("    ~ts~n", [L]) end, Wrapped)
    end,
    io:format("~n").

%% Simple word-wrap.
wrap(Text, Width) ->
    Words = string:tokens(Text, " "),
    wrap_words(Words, Width, [], []).

wrap_words([], _, [], Acc) -> lists:reverse(Acc);
wrap_words([], _, Cur, Acc) ->
    lists:reverse([string:join(lists:reverse(Cur), " ") | Acc]);
wrap_words([W | Rest], Width, Cur, Acc) ->
    Line = string:join(lists:reverse([W | Cur]), " "),
    if
        length(Line) =< Width ->
            wrap_words(Rest, Width, [W | Cur], Acc);
        Cur =:= [] ->
            wrap_words(Rest, Width, [], [W | Acc]);
        true ->
            wrap_words([W | Rest], Width,
                       [], [string:join(lists:reverse(Cur), " ") | Acc])
    end.
