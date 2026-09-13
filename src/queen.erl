%%%-------------------------------------------------------------------
%%% @doc Query expansion and disco node resolution.
%%%
%%% <dl>
%%%   <dt>`expand/1'</dt>
%%%   <dd>Splits a query into focused sub-queries (HF topics with a
%%%       local keyword fallback) to improve agent recall. The only
%%%       transformation the default Emquest pipeline applies to a
%%%       query before fan-out.</dd>
%%%
%%%   <dt>`disco_nodes/0', `pop_seeds/0', `emquest_pop_port/0'</dt>
%%%   <dd>Resolve em_disco HTTP base URLs and em-pop gossip seeds from
%%%       `emergence.conf'.</dd>
%%% </dl>
%%%
%%% === Node URL resolution (`disco_nodes/0') ===
%%%
%%% Reads the `[em_disco]' section from `emergence.conf'.
%%% Accepts entries as `host:port' or bare host:
%%%
%%% ```
%%% localhost              -> http://localhost:8080
%%% localhost:8080         -> http://localhost:8080
%%% localhost:9000         -> http://localhost:9000
%%% em-disco.roques.me     -> https://em-disco.roques.me
%%% em-disco.roques.me:443 -> https://em-disco.roques.me
%%% em-disco.roques.me:8080-> http://em-disco.roques.me:8080
%%% '''
%%%
%%% Resolution rules:
%%% <ul>
%%%   <li>`localhost' and `127.0.0.1' always use `http://'</li>
%%%   <li>Port 443 uses `https://' and omits the port from the URL</li>
%%%   <li>Any other explicit port uses `http://' with the port</li>
%%%   <li>Bare remote host defaults to `https://' on port 443</li>
%%% </ul>
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(queen).

-export([expand/1, disco_nodes/0,
         pop_seeds/0, emquest_pop_port/0,
         conf_path/0, parse_conf/1]).

-define(REGISTRY_CACHE, queen_registry_cache).

%%====================================================================
%% Query expansion
%%====================================================================

%% @doc Expand a query into focused sub-queries for agent fan-out.
%%
%% The original query is always the first element of the returned
%% list, ensuring it is always included in the fan-out. Expansion is
%% HF/local only: the query is sent to the local HF topic-extraction
%% microservice, falling back to a local keyword split when that is
%% unavailable.
%% @end
-spec expand(binary()) -> [binary()].
expand(Query) ->
    [Query | [K || K <- fallback_topics(Query), K =/= Query]].

%% @private Local keyword fallback: split a phrase into topic words,
%% dropping short tokens and common FR/EN stopwords.
-spec local_keywords(binary()) -> [binary()].
local_keywords(Query) ->
    Parts = binary:split(Query,
        [<<" ">>,<<",">>,<<".">>,<<";">>,<<":">>,<<"?">>,<<"!">>,
         <<"(">>,<<")">>,<<"/">>,<<"-">>],
        [global, trim_all]),
    Kw = [string:lowercase(P) || P <- Parts, byte_size(P) >= 3],
    Kw2 = [K || K <- Kw, not lists:member(K, stopwords())],
    lists:sublist(lists:usort(Kw2), 6).

-spec stopwords() -> [binary()].
stopwords() ->
    [<<"les">>,<<"des">>,<<"une">>,<<"que">>,<<"qui">>,<<"pour">>,
     <<"avec">>,<<"dans">>,<<"sur">>,<<"est">>,<<"aux">>,<<"ces">>,
     <<"son">>,<<"ses">>,<<"nos">>,<<"vos">>,<<"leur">>,<<"the">>,
     <<"and">>,<<"for">>,<<"with">>,<<"from">>,<<"this">>,<<"that">>,
     <<"are">>,<<"was">>,<<"you">>,<<"your">>].

%% @private Query the local HF topic-extraction microservice (KeyBERT +
%% multilingual MiniLM). Returns [] on any error so callers fall back.
-spec hf_topics(binary()) -> [binary()].
hf_topics(Query) ->
    _ = application:ensure_all_started(inets),
    Body = iolist_to_binary(json:encode(#{<<"query">> => Query})),
    Req  = {"http://127.0.0.1:8085/topics", [], "application/json", Body},
    case httpc:request(post, Req, [{timeout, 4000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBin}} ->
            case catch json:decode(RespBin) of
                #{<<"topics">> := Ts} when is_list(Ts) ->
                    [T || T <- Ts, is_binary(T), T =/= <<>>];
                _ -> []
            end;
        _ -> []
    end.

%% @private HF topics first, local keyword split as fallback.
-spec fallback_topics(binary()) -> [binary()].
fallback_topics(Query) ->
    case hf_topics(Query) of
        []  -> local_keywords(Query);
        Ts  -> Ts
    end.

%%====================================================================
%% Disco node discovery
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Returns the list of disco HTTP(S) base URLs to query.
%%
%% Merges local nodes from emergence.conf with optional remote
%% registry nodes. Local nodes always come first.
%% Remote registry is cached in ETS for registry_ttl seconds.
%% @end
%%--------------------------------------------------------------------
-spec disco_nodes() -> [string()].
disco_nodes() ->
    Conf   = read_disco_conf(),
    Local  = local_node_urls(Conf),
    Remote = case use_registry(Conf) of
        false -> [];
        true  -> fetch_registry_cached(Conf)
    end,
    lists:foldl(fun(N, Acc) ->
        case lists:member(N, Acc) of
            true  -> Acc;
            false -> Acc ++ [N]
        end
    end, Local, Remote).

%%--------------------------------------------------------------------
%% @doc Return em_pop bootstrap seed endpoints from `emergence.conf'.
%%
%% Reads host entries from `[em_disco] nodes' and the shared gossip
%% port from `[em_disco] pop_port'.  Returns a `{Host, Port}' list
%% that `emquest_pop:init/1' uses to seed Emquest's peer table.
%%
%% Returns `[]' when `pop_port' is absent — em_pop seeding is skipped
%% and Emquest starts with an empty peer table (normal during early
%% Phase 2 deployment when not all seeds are upgraded yet).
%% @end
%%--------------------------------------------------------------------
-spec pop_seeds() -> [{string(), pos_integer()}].
pop_seeds() ->
    DiscoConf = read_disco_conf(),
    Default = case maps:get("pop_port", DiscoConf, undefined) of
                  undefined -> 9100;
                  PortStr   -> list_to_integer(string:trim(PortStr))
              end,
    NodesStr = maps:get("nodes", DiscoConf,
                   maps:get("host", DiscoConf, "localhost")),
    Entries = string:split(NodesStr, ",", all),
    lists:filtermap(fun(E) ->
        case string:trim(E) of
            "" -> false;
            T  ->
                case string:split(T, ":", trailing) of
                    [H, P] ->
                        try {true, {string:trim(H), list_to_integer(string:trim(P))}}
                        catch _:_ -> {true, {string:trim(T), Default}} end;
                    [H] -> {true, {string:trim(H), Default}}
                end
        end
    end, Entries).

%%--------------------------------------------------------------------
%% @doc Return the em_pop listener port for the Emquest node.
%%
%% Reads `[emquest] pop_port' from `emergence.conf'. Default: 9100.
%%
%% Example:
%%   [emquest]
%%   pop_port = 9100
%% @end
%%--------------------------------------------------------------------
-spec emquest_pop_port() -> pos_integer().
emquest_pop_port() ->
    case conf_path() of
        undefined ->
            9100;
        Path ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    Section = maps:get("emquest", parse_conf(Bin), #{}),
                    case maps:get("pop_port", Section, undefined) of
                        undefined -> 9100;
                        PortStr   -> list_to_integer(string:trim(PortStr))
                    end;
                _ ->
                    9100
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Converts the nodes config into HTTP(S) base URLs.
%% @end
%%--------------------------------------------------------------------
-spec local_node_urls(map()) -> [string()].
local_node_urls(Conf) ->
    case maps:get("nodes", Conf, undefined) of
        undefined ->
            %% Legacy server_url key.
            [maps:get("server_url", Conf, "http://localhost:8080")];
        NodesStr ->
            Entries = string:split(NodesStr, ",", all),
            lists:filtermap(fun(Entry) ->
                case string:trim(Entry) of
                    "" -> false;
                    E  -> {true, entry_to_url(E)}
                end
            end, Entries)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Converts a "host" or "host:port" entry to an HTTP(S) URL.
%%
%% localhost / 127.0.0.1   → http://host:port  (port defaults to 8080)
%% remote host, port 443   → https://host       (standard, omit port)
%% remote host, other port → http://host:port   (explicit non-TLS)
%% bare remote host        → https://host       (defaults to 443/TLS)
%% @end
%%--------------------------------------------------------------------
-spec entry_to_url(string()) -> string().
entry_to_url(Entry) ->
    case string:split(Entry, ":", trailing) of
        [Host, PortStr] ->
            H = string:trim(Host),
            case catch list_to_integer(string:trim(PortStr)) of
                P when is_integer(P) -> build_url(H, P, explicit);
                _                    -> build_url(H, 8080, default)
            end;
        [Host] ->
            H = string:trim(Host),
            build_url(H, default, default)
    end.

-spec build_url(string(), integer() | default, explicit | default) -> string().
%% localhost / 127.0.0.1 — always plain HTTP
build_url("localhost",  Port, _) ->
    P = if is_integer(Port) -> Port; true -> 8080 end,
    "http://localhost:" ++ integer_to_list(P);
build_url("127.0.0.1", Port, _) ->
    P = if is_integer(Port) -> Port; true -> 8080 end,
    "http://127.0.0.1:" ++ integer_to_list(P);
%% Remote host, port 443 or no port — HTTPS, omit port
build_url(Host, 443,     _)       -> "https://" ++ Host;
build_url(Host, default, default) -> "https://" ++ Host;
%% Remote host, explicit non-443 port — HTTP with port
build_url(Host, Port, explicit) ->
    "http://" ++ Host ++ ":" ++ integer_to_list(Port).

use_registry(Conf) ->
    maps:get("use_registry", Conf, "false") =:= "true".

%%--------------------------------------------------------------------
%% @private
%% @doc Returns cached registry nodes or fetches them if stale.
%% @end
%%--------------------------------------------------------------------
-spec fetch_registry_cached(map()) -> [string()].
fetch_registry_cached(Conf) ->
    case maps:get("registry_url", Conf, undefined) of
        undefined -> [];
        Url ->
            TTL = list_to_integer(maps:get("registry_ttl", Conf, "300")),
            ensure_cache_table(),
            Now = erlang:system_time(second),
            case ets:lookup(?REGISTRY_CACHE, Url) of
                [{_, Nodes, Expiry}] when Expiry > Now ->
                    Nodes;
                _ ->
                    Nodes = fetch_registry(Url),
                    ets:insert(?REGISTRY_CACHE, {Url, Nodes, Now + TTL}),
                    Nodes
            end
    end.

ensure_cache_table() ->
    case ets:whereis(?REGISTRY_CACHE) of
        undefined ->
            ets:new(?REGISTRY_CACHE,
                    [set, named_table, public, {read_concurrency, true}]);
        _ -> ok
    end.

-spec fetch_registry(string()) -> [string()].
fetch_registry(Url) ->
    case httpc:request(get, {Url, []}, [{timeout, 5000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            try
                #{<<"nodes">> := Nodes} = json:decode(Body),
                [binary_to_list(maps:get(<<"url">>, N, <<>>))
                 || N <- Nodes,
                    is_map(N),
                    maps:get(<<"open">>, N, false) =:= true,
                    maps:get(<<"url">>,  N, <<>>) =/= <<>>]
            catch _:_ -> [] end;
        _ -> []
    end.

%%====================================================================
%% Configuration
%%====================================================================

read_disco_conf() ->
    case conf_path() of
        undefined -> #{};
        Path ->
            case file:read_file(Path) of
                {ok, Bin} -> maps:get("em_disco", parse_conf(Bin), #{});
                _         -> #{}
            end
    end.

-spec conf_path() -> string() | undefined.
conf_path() ->
    case {os:getenv("HOME"), os:getenv("APPDATA"), os:type()} of
        {false, false, _}    -> undefined;
        {false, AppData, _}  ->
            filename:join([AppData, "emergence", "emergence.conf"]);
        {Home, _, {unix, _}} ->
            filename:join([Home, ".config", "emergence", "emergence.conf"]);
        {Home, _, _}         ->
            filename:join([Home, "AppData", "Roaming", "emergence",
                           "emergence.conf"])
    end.

-spec parse_conf(binary()) -> map().
parse_conf(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    {Map, _} = lists:foldl(fun parse_line/2, {#{}, ""}, Lines),
    Map.

parse_line(<<";", _/binary>>, Acc) -> Acc;
parse_line(<<"#", _/binary>>, Acc) -> Acc;
parse_line(<<"[", Rest/binary>>, {Map, _Sec}) ->
    Sec = string:trim(binary_to_list(Rest), both, "]\r\n "),
    {Map#{Sec => #{}}, Sec};
parse_line(Line, {Map, Sec}) when Sec =/= "" ->
    case binary:split(Line, <<"=">>) of
        [K, V] ->
            Key = string:trim(binary_to_list(K)),
            Val = string:trim(binary_to_list(V)),
            {Map#{Sec => maps:put(Key, Val, maps:get(Sec, Map, #{}))}, Sec};
        _ -> {Map, Sec}
    end;
parse_line(_, Acc) -> Acc.
