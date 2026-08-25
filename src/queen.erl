%%%-------------------------------------------------------------------
%%% @doc LLM interface for query expansion, ranking, and synthesis.
%%%
%%% Provides three capabilities built on configurable LLM providers
%%% (Mistral, Ollama, OpenAI, Claude):
%%%
%%% <dl>
%%%   <dt>`expand/1'</dt>
%%%   <dd>Used by the default Emquest pipeline. Splits long queries
%%%       into 2–3 focused sub-queries to improve agent recall.</dd>
%%%
%%%   <dt>`rank/2'</dt>
%%%   <dd>Re-ranks a list of results by relevance to the original
%%%       query. <em>Not called by the default Emquest pipeline.</em>
%%%       Available for external clients (MCP, EmPy, custom
%%%       integrations) that want LLM-assisted ranking.</dd>
%%%
%%%   <dt>`synthesize/2'</dt>
%%%   <dd>Generates a prose answer from the top-ranked results.
%%%       <em>Not called by the default Emquest pipeline.</em>
%%%       Available for external clients that want a summary
%%%       alongside raw results.</dd>
%%% </dl>
%%%
%%% === Configuration (`emergence.conf') ===
%%%
%%% ```
%%% [llm]
%%% provider      = mistral
%%% model         = mistral-small-latest
%%% temperature   = 0.3
%%% system_prompt = You are a search assistant. Be concise.
%%% '''
%%%
%%% Supported providers: `mistral', `ollama', `openai', `claude'.
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

-export([expand/1, rank/2, synthesize/2, disco_nodes/0,
         pop_seeds/0, emquest_pop_port/0,
         conf_path/0, parse_conf/1]).

-define(DEFAULT_SYSTEM_PROMPT,
    "You are a search assistant. Be concise and precise.").

-define(REGISTRY_CACHE, queen_registry_cache).

%%====================================================================
%% Query expansion
%%====================================================================

%% @doc Expand a query into focused sub-queries for agent fan-out.
%%
%% Short queries (under 25 bytes) are returned as-is — no LLM call
%% is made. For longer queries, the configured LLM extracts 2–3
%% search keywords or sub-queries.
%%
%% The original query is always the first element of the returned
%% list, ensuring it is always included in the fan-out regardless
%% of what the LLM returns.
%%
%% This is the only `queen' function called by the default Emquest
%% pipeline. See {@link rank/2} and {@link synthesize/2} for
%% optional LLM capabilities available to external clients.
%% @end
-spec expand(binary()) -> [binary()].
expand(Query) when byte_size(Query) < 25 ->
    [Query | [K || K <- fallback_topics(Query), K =/= Query]];
expand(Query) ->
    Conf   = read_llm_conf(),
    Prompt = <<"Extract 2 to 3 simple search keywords or sub-queries from "
               "this query. Reply ONLY with a raw JSON array of strings, "
               "no markdown, no explanation.\n"
               "Example: [\"term one\", \"term two\"]\n\n"
               "Query: ", Query/binary>>,
    HandlerConf = handler_conf(
        maps:get(provider, Conf, <<"mistral">>),
        Conf,
        <<"You extract search keywords. Reply only with a JSON array of strings.">>
    ),
    SubQueries = case call_handler_timeout(maps:get(provider, Conf, <<"mistral">>),
                                   Prompt, HandlerConf, llm_timeout(Conf)) of
        {ok, Text} -> case parse_json_list(Text) of [] -> fallback_topics(Query); Lst -> Lst end;
        _          -> fallback_topics(Query)
    end,
    Deduped = lists:usort(SubQueries),
    [Query | lists:delete(Query, Deduped)].

%% @private Run an LLM handler with a hard timeout so a slow or unavailable
%% provider (e.g. ollama down) falls back to topic extraction instead of
%% hanging the request. Returns {error, timeout} past the deadline.
-spec call_handler_timeout(binary(), binary(), map(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
call_handler_timeout(Provider, Prompt, Conf, TimeoutMs) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Parent ! {Ref, (catch call_handler(Provider, Prompt, Conf))}
    end),
    receive
        {Ref, Res} -> erlang:demonitor(MRef, [flush]), Res;
        {'DOWN', MRef, _, _, Reason} -> {error, Reason}
    after TimeoutMs ->
        exit(Pid, kill), erlang:demonitor(MRef, [flush]), {error, timeout}
    end.

%% @private LLM call timeout in ms from [llm] timeout_ms (default 4000).
-spec llm_timeout(map()) -> pos_integer().
llm_timeout(Conf) ->
    case maps:get(timeout_ms, Conf, undefined) of
        undefined            -> 4000;
        B when is_binary(B)  -> try binary_to_integer(B) catch _:_ -> 4000 end;
        N when is_integer(N), N > 0 -> N;
        _                    -> 4000
    end.

%% @private Local keyword fallback (no LLM): split a phrase into topic
%% words, dropping short tokens and common FR/EN stopwords.
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
%% Synthesis
%%====================================================================

%% @doc Generate a prose answer from the top-ranked results.
%%
%% Formats the top 5 items as context and asks the configured LLM
%% to answer `Query' in 2–4 plain-text sentences.
%%
%% <em>Not called by the default Emquest pipeline.</em> Available
%% for external clients (MCP, EmPy, custom integrations) that want
%% a prose summary alongside raw results.
%%
%% Returns `<<>>' if the LLM call fails.
%% @end
-spec synthesize(binary(), [map()]) -> binary().
synthesize(Query, RankedItems) ->
    Conf      = read_llm_conf(),
    Provider  = maps:get(provider, Conf, <<"mistral">>),
    SysPrompt = ensure_binary(maps:get(system_prompt, Conf,
                                       ?DEFAULT_SYSTEM_PROMPT)),
    TopN    = lists:sublist(RankedItems, 5),
    Context = iolist_to_binary(json:encode(
        [begin
            Props = maps:get(<<"properties">>, Item, Item),
            Label = maps:get(<<"title">>,  Props,
                        maps:get(<<"label">>,  Props, <<>>)),
            Value = maps:get(<<"resume">>, Props,
                        maps:get(<<"value">>,  Props, <<>>)),
            #{<<"l">> => Label, <<"v">> => Value}
         end || Item <- TopN]
    )),
    Prompt = <<"Answer or summarise the following query in 2-4 sentences. "
               "Use the provided search results as context. "
               "Reply in plain text only — no JSON, no markdown, no bullet points.\n\n"
               "Query: ", Query/binary, "\n\n"
               "Top results context:\n", Context/binary>>,
    HandlerConf = handler_conf(Provider, Conf, SysPrompt),
    case call_handler(Provider, Prompt, HandlerConf) of
        {ok, Text} -> Text;
        _          -> <<>>
    end.

%%====================================================================
%% Result ranking
%%====================================================================

%% @doc Re-rank a list of result maps by relevance to `Query'.
%%
%% Returns the same items in a new order with a `<<"score">>' key
%% added to each (0–3, where 3 is most relevant). Items not covered
%% by the LLM ranking are appended at the end in their original order.
%%
%% <em>Not called by the default Emquest pipeline.</em> Available
%% for external clients that want LLM-assisted ranking after
%% collecting results from {@link emquest_handler} or directly from
%% em_disco.
%%
%% Returns the input list unchanged if `Items' is empty.
%% @end
-spec rank(binary(), [map()]) -> [map()].
rank(_Query, []) -> [];
rank(Query, Items) ->
    Conf = read_llm_conf(),
    Indexed = lists:zip(lists:seq(0, length(Items) - 1), Items),
    IndexedJson = iolist_to_binary(json:encode(
        [begin
            Props = maps:get(<<"properties">>, Item, Item),
            Label = maps:get(<<"title">>,  Props,
                        maps:get(<<"label">>,  Props, <<>>)),
            Value = maps:get(<<"resume">>, Props,
                        maps:get(<<"value">>,  Props, <<>>)),
            #{<<"i">> => I, <<"l">> => Label, <<"v">> => Value}
         end || {I, Item} <- Indexed]
    )),
    Prompt = <<"You receive search results and a query. "
               "Return ONLY a JSON array of the result indices sorted "
               "by relevance to the query (most relevant first). "
               "Keep ALL indices. No explanation, no markdown.\n"
               "Example for 4 results: [2, 0, 3, 1]\n\n"
               "Query: ", Query/binary, "\n\n"
               "Results:\n", IndexedJson/binary>>,
    HandlerConf = handler_conf(
        maps:get(provider, Conf, <<"mistral">>),
        Conf#{temperature => 0.1},
        <<"You rank search results. Reply only with a JSON array of integers.">>
    ),
    RankedIndices = case call_handler(maps:get(provider, Conf, <<"mistral">>),
                                      Prompt, HandlerConf) of
        {ok, Text} ->
            Parsed  = parse_json_integers(Text),
            All     = lists:seq(0, length(Items) - 1),
            Missing = All -- Parsed,
            Parsed ++ Missing;
        _ ->
            lists:seq(0, length(Items) - 1)
    end,
    Total    = length(RankedIndices),
    ItemsArr = list_to_tuple(Items),
    lists:filtermap(fun({Pos, Idx}) ->
        case Idx >= 0 andalso Idx < tuple_size(ItemsArr) of
            true ->
                Item  = element(Idx + 1, ItemsArr),
                Score = score_for_position(Pos, Total),
                {true, Item#{<<"score">> => Score}};
            false -> false
        end
    end, lists:zip(lists:seq(0, length(RankedIndices) - 1), RankedIndices)).

score_for_position(_Pos, Total) when Total =< 1 -> 3;
score_for_position(Pos, Total) ->
    Quartile = (Pos * 4) div Total,
    max(0, 3 - Quartile).

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
    case maps:get("pop_port", DiscoConf, undefined) of
        undefined ->
            [];
        PortStr ->
            PopPort = list_to_integer(string:trim(PortStr)),
            Hosts   = extract_disco_hosts(DiscoConf),
            [{H, PopPort} || H <- Hosts]
    end.

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

%% @private
%% @doc Extract bare hostnames from `[em_disco] nodes' (strips ports).
-spec extract_disco_hosts(map()) -> [string()].
extract_disco_hosts(Conf) ->
    NodesStr = maps:get("nodes", Conf,
                   maps:get("host", Conf, "localhost")),
    Entries  = string:split(NodesStr, ",", all),
    lists:filtermap(fun(Entry) ->
        case string:trim(Entry) of
            "" -> false;
            E  ->
                H = case string:split(E, ":", trailing) of
                    [Host, _Port] -> string:trim(Host);
                    [Host]        -> string:trim(Host)
                end,
                {true, H}
        end
    end, Entries).

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
%% LLM dispatch
%%====================================================================

call_handler(<<"mistral">>, Prompt, Conf) -> mistral_handler:generate(Prompt, Conf);
call_handler(<<"ollama">>,  Prompt, Conf) -> ollama_handler:generate(Prompt, Conf);
call_handler(<<"openai">>,  Prompt, Conf) -> openai_handler:generate(Prompt, Conf);
call_handler(<<"claude">>,  Prompt, Conf) -> claude_handler:generate(Prompt, Conf);
call_handler(_, Prompt, Conf)             -> mistral_handler:generate(Prompt, Conf).

handler_conf(Provider, Conf, SysPrompt) ->
    Base = case Provider of
        <<"mistral">> -> mistral_handler:get_env_config();
        <<"ollama">>  -> (catch ollama_handler:get_env_config());
        <<"openai">>  -> (catch openai_handler:get_env_config());
        <<"claude">>  -> (catch claude_handler:get_env_config());
        _             -> mistral_handler:get_env_config()
    end,
    Overrides = maps:filter(fun(_, V) -> V =/= undefined end, #{
        endpoint      => maps:get(endpoint,    Conf, undefined),
        model         => maps:get(model,       Conf, undefined),
        temperature   => maps:get(temperature, Conf, undefined),
        system_prompt => ensure_binary(SysPrompt)
    }),
    case is_map(Base) of
        true  -> maps:merge(Base, Overrides);
        false -> Overrides
    end.

%%====================================================================
%% JSON helpers
%%====================================================================

parse_json_list(Text) ->
    try
        List = json:decode(strip_fences(Text)),
        [Q || Q <- List, is_binary(Q)]
    catch _:_ -> [] end.

parse_json_integers(Text) ->
    try
        List = json:decode(strip_fences(Text)),
        [I || I <- List, is_integer(I)]
    catch _:_ -> [] end.

strip_fences(Text) ->
    T1 = re:replace(Text, <<"^```(json)?\\s*">>, <<"">>,
                    [{return, binary}, multiline]),
    re:replace(T1, <<"\\s*```$">>, <<"">>,
               [{return, binary}, multiline]).

%%====================================================================
%% Configuration
%%====================================================================

read_llm_conf() ->
    case conf_path() of
        undefined -> #{};
        Path ->
            case file:read_file(Path) of
                {ok, Bin} -> parse_llm_section(parse_conf(Bin));
                _         -> #{}
            end
    end.

read_disco_conf() ->
    case conf_path() of
        undefined -> #{};
        Path ->
            case file:read_file(Path) of
                {ok, Bin} -> maps:get("em_disco", parse_conf(Bin), #{});
                _         -> #{}
            end
    end.

parse_llm_section(ConfMap) ->
    Section = maps:get("llm", ConfMap, #{}),
    maps:fold(fun(K, V, Acc) ->
        Value = case K of
            "temperature" ->
                try list_to_float(V)
                catch _:_ ->
                    try float(list_to_integer(V))
                    catch _:_ -> 0.3 end
                end;
            _ -> list_to_binary(V)
        end,
        Acc#{list_to_atom(K) => Value}
    end, #{}, Section).

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

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8);
ensure_binary(_)                   -> <<>>.
