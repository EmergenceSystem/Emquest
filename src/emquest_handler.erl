%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_handler — Streaming HTTP Handler (Server-Sent Events)
%%%
%%% GET  /       → serves index.html
%%% POST /query  → SSE stream of progress events + final results
%%%
%%% === SSE event types ===
%%%
%%% Every event is a line:  data: <json>\n\n
%%%
%%%   {"type": "status",  "message": "Expanding query..."}
%%%   {"type": "results", "items":   [...]}
%%%   {"type": "error",   "message": "..."}
%%%
%%% The client renders status events as a live progress log and
%%% replaces it with the results list when the "results" event arrives.
%%%
%%% === Item shape (inside "results") ===
%%%
%%%   { "label": "...", "value": "...",
%%%     "url":   "https://..."    (web result — optional)
%%%     "ips":   ["1.2.3.4"]     (DNS result — optional)
%%%     "score": 0-3 }           (LLM relevance rank)
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%%--------------------------------------------------------------------
init(Req0, index) ->
    Path = filename:join([code:priv_dir(emquest), "templates", "index.html"]),
    {Code, Body, CT} = case file:read_file(Path) of
        {ok, Bin} -> {200, Bin, <<"text/html">>};
        {error, R} ->
            logger:error("[emquest] index.html read failed: ~p", [R]),
            {500, <<"Internal Server Error">>, <<"text/plain">>}
    end,
    {ok, cowboy_req:reply(Code, #{<<"content-type">> => CT}, Body, Req0), index};

init(Req0, query) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, RawBody, Req1} = cowboy_req:read_body(Req0),
            handle_query(RawBody, Req1),
            {ok, Req1, query};
        _ ->
            {ok, cowboy_req:reply(405,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":\"Use POST\"}">>, Req0), query}
    end.

%%====================================================================
%% Pipeline
%%====================================================================

handle_query(RawBody, Req0) ->
    %% Open SSE stream
    Req = cowboy_req:stream_reply(200, #{
        <<"content-type">>  => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">>    => <<"keep-alive">>,
        <<"access-control-allow-origin">> => <<"*">>
    }, Req0),

    try json:decode(RawBody) of
        #{<<"query">> := Query} when is_binary(Query) ->
            run_pipeline(Query, Req);
        _ ->
            sse(Req, error, <<"Missing or invalid 'query' field">>)
    catch _:_ ->
        sse(Req, error, <<"Invalid JSON body">>)
    end.

run_pipeline(Query, Req) ->
    %% Step 1 — expand query into sub-queries via LLM
    sse(Req, status, <<"Expanding query...">>),
    SubQueries = queen:expand(Query),
    sse(Req, status, iolist_to_binary([
        "Querying agents with ",
        integer_to_binary(length(SubQueries)), " sub-query(ies)..."
    ])),

    %% Step 2 — fan-out to disco in parallel, stream progress
    Parent = self(),
    Pids = [spawn(fun() ->
                Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
                case fetch_from_disco(Body) of
                    {ok, #{<<"embryo_list">> := Items}} ->
                        Parent ! {disco_result, self(), Q, Items};
                    {error, R} ->
                        logger:warning("[emquest] disco fail ~s: ~p", [Q, R]),
                        Parent ! {disco_result, self(), Q, []}
                end
             end) || Q <- SubQueries],

    AllItems = collect_disco(Pids, Req, []),

    %% Step 3 — deduplicate by URL (first occurrence wins)
    Deduped = deduplicate(AllItems),
    sse(Req, status, iolist_to_binary([
        integer_to_binary(length(Deduped)),
        " unique result(s). Ranking with LLM..."
    ])),

    %% Step 4 — LLM ranks (sorts), never hides results
    Ranked = queen:rank(Query, Deduped),

    %% Step 5 — LLM synthesises a prose answer from the top results
    sse(Req, status, <<"Generating answer...">>),
    Answer = queen:synthesize(Query, Ranked),
    case Answer of
        <<>> -> ok;
        _    -> sse(Req, answer, Answer)
    end,

    %% Step 6 — normalise items for the client and stream
    ClientItems = [normalise_item(Item) || Item <- Ranked],
    sse_results(Req, ClientItems).

%%====================================================================
%% Disco collection
%%====================================================================

collect_disco([], _Req, Acc) -> Acc;
collect_disco([Pid | Rest], Req, Acc) ->
    receive
        {disco_result, Pid, SubQ, Items} ->
            sse(Req, status, iolist_to_binary([
                "Got ", integer_to_binary(length(Items)),
                " result(s) for: \"", SubQ, "\""
            ])),
            collect_disco(Rest, Req, Acc ++ Items)
    after 8000 ->
        logger:warning("[emquest] disco timeout pid ~p", [Pid]),
        collect_disco(Rest, Req, Acc)
    end.

%%====================================================================
%% Deduplication
%%====================================================================

deduplicate(Items) ->
    {Uniq, _} = lists:foldl(fun(Item, {Acc, Seen}) ->
        Props = maps:get(<<"properties">>, Item, #{}),
        Url   = maps:get(<<"url">>, Props, <<>>),
        case Url =:= <<>> orelse sets:is_element(Url, Seen) of
            true  -> {Acc, Seen};
            false -> {[Item | Acc], sets:add_element(Url, Seen)}
        end
    end, {[], sets:new()}, Items),
    lists:reverse(Uniq).

%%====================================================================
%% Item normalisation
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Flattens an embryo map into a client-ready item.
%%
%% Type detection (no hidden results — everything goes through):
%%   url present  → web result  → render as link + resume
%%   ips present  → DNS result  → render as IP badge list
%%   neither      → generic     → render as label + value
%%
%% score (0-3) is injected by queen:rank/2 and forwarded as-is.
%% @end
%%--------------------------------------------------------------------
normalise_item(Item) ->
    Props = maps:get(<<"properties">>, Item, Item),
    Score = maps:get(<<"score">>, Item, 0),

    Url   = first_defined(Props, [<<"url">>],                      null),
    Label = first_defined(Props, [<<"title">>,<<"label">>,
                                  <<"domain">>],                   <<"Result">>),
    Value = first_defined(Props, [<<"resume">>,<<"value">>,
                                  <<"description">>],              <<>>),
    Ips   = first_defined(Props, [<<"ips">>],                      null),

    Base = #{<<"label">> => Label, <<"value">> => Value,
             <<"score">> => Score},

    case {Url, Ips} of
        {null, [_|_]} -> Base#{<<"ips">>  => Ips};   %% DNS
        {null, _}     -> Base;                         %% generic
        _             -> Base#{<<"url">>  => Url}      %% web
    end.

first_defined(_Props, [], Default) -> Default;
first_defined(Props, [Key | Rest], Default) ->
    case maps:get(Key, Props, undefined) of
        undefined -> first_defined(Props, Rest, Default);
        null      -> first_defined(Props, Rest, Default);
        V         -> V
    end.

%%====================================================================
%% Disco HTTP
%%====================================================================

fetch_from_disco(Body) ->
    case httpc:request(post,
                       {disco_url(), [], "application/json",
                        binary_to_list(Body)},
                       [{timeout, 10000}], []) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            try {ok, json:decode(iolist_to_binary(RespBody))}
            catch _:_ -> {error, invalid_json} end;
        {ok, {{_, Code, _}, _, _}} -> {error, {http, Code}};
        {error, R}                 -> {error, R}
    end.

disco_url() ->
    case queen:conf_path() of
        undefined -> "http://localhost:8080/query";
        Path ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    Conf = queen:parse_conf(Bin),
                    Base = maps:get("server_url",
                               maps:get("em_disco", Conf, #{}),
                               "http://localhost:8080"),
                    Base ++ "/query";
                _ -> "http://localhost:8080/query"
            end
    end.

%%====================================================================
%% SSE helpers
%%====================================================================

sse(Req, Type, Message) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">>    => atom_to_binary(Type, utf8),
        <<"message">> => Message
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).

sse_results(Req, Items) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">>  => <<"results">>,
        <<"items">> => Items
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, fin, Req).
