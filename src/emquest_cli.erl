%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_cli — Interactive Shell Client
%%%
%%% Merged from em_client into the emquest application.
%%% Calls em_disco:query/1 directly (no HTTP round-trip) and prints
%%% results to the console.
%%%
%%% Usage from rebar3 shell:
%%%   emquest_cli:query("google.com").
%%%   emquest_cli:query(<<"some search">>).
%%%
%%% em_disco must be reachable from the same node.
%%% In the rebar3 shell, add em_disco to your deps or start it first:
%%%   application:ensure_all_started(em_disco).
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_cli).

-export([query/1]).

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

%%====================================================================
%% HTTP
%%====================================================================

post_to_disco(Body) ->
    Url = disco_url() ++ "/query",
    case httpc:request(post,
                       {Url, [], "application/json", binary_to_list(Body)},
                       [{timeout, 10000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} -> {ok, RespBody};
        {ok, {{_, Code, _}, _, _}}       -> {error, {http, Code}};
        {error, Reason}                  -> {error, Reason}
    end.

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

    Url    = maps:get(<<"url">>,    Props, undefined),
    Title  = maps:get(<<"title">>,  Props,
             maps:get(<<"label">>,  Props,
             maps:get(<<"domain">>, Props, undefined))),
    Resume = maps:get(<<"resume">>, Props,
             maps:get(<<"value">>,  Props, undefined)),
    Ips    = maps:get(<<"ips">>,    Props, undefined),

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
