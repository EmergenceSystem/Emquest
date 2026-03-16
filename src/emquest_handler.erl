%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_handler — Streaming HTTP Handler (Server-Sent Events)
%%%
%%% GET  /       → serves index.html
%%% POST /query  → SSE stream of progress events + final results
%%%
%%% SSE event types:
%%%
%%%   {"type": "status",  "message": "..."}
%%%   {"type": "item",    "item": {...}, "sid": N}   streamed immediately
%%%   {"type": "reorder", "sids": [N,...], "scores": {N: 0-3,...}}
%%%   {"type": "answer",  "message": "..."}          LLM synthesis
%%%   {"type": "error",   "message": "..."}
%%%
%%% Multi-disco fan-out:
%%%
%%%   queen:disco_nodes/0 returns the list of disco HTTP base URLs
%%%   (local + optional remote registry).  The pipeline spawns one
%%%   process per (sub-query × disco node) combination so all sources
%%%   are queried fully in parallel.
%%%   Deduplication by URL handles any overlap between nodes.
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
    %% Step 1 — expand query into sub-queries
    sse(Req, status, <<"Expanding query...">>),
    SubQueries = queen:expand(Query),

    %% Step 2 — discover all disco nodes (local + registry)
    Nodes = queen:disco_nodes(),
    sse(Req, status, iolist_to_binary([
        "Querying ", integer_to_binary(length(Nodes)), " disco node(s) with ",
        integer_to_binary(length(SubQueries)), " sub-query(ies)..."
    ])),

    %% Step 3 — cartesian fan-out: one spawn per (sub-query × disco node).
    %% All processes run in parallel regardless of how many nodes there are.
    %% Disco URLs are read once here so spawned closures reuse them.
    Parent = self(),
    DiscoUrls = [Node ++ "/query" || Node <- Nodes],
    Pids = [spawn(fun() ->
                Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
                Tag  = iolist_to_binary([Q, " @ ", Url]),
                case fetch_from_disco(Body, Url) of
                    {ok, #{<<"embryo_list">> := Items}} ->
                        Parent ! {disco_result, self(), Tag, Items};
                    {error, R} ->
                        logger:warning("[emquest] disco fail ~s: ~p", [Tag, R]),
                        Parent ! {disco_result, self(), Tag, []}
                end
             end) || Q <- SubQueries, Url <- DiscoUrls],

    %% Collect results, streaming each item immediately as it arrives.
    TaggedItems = collect_disco_streaming(length(Pids), Req, [], 0),

    %% Step 4 — deduplicate by URL (first occurrence wins)
    DedupedTagged = deduplicate_tagged(TaggedItems),
    RawItems      = [Item || {_Sid, Item} <- DedupedTagged],

    sse(Req, status, iolist_to_binary([
        integer_to_binary(length(DedupedTagged)),
        " unique result(s). Ranking with LLM..."
    ])),

    %% Step 5 — rank; result is the same list reordered with scores
    Ranked = queen:rank(Query, RawItems),

    %% Rebuild {Sid, Score} in ranked order — O(n) map lookup
    SidIndex = maps:from_list(
        [{maps:remove(<<"score">>, Item), Sid} || {Sid, Item} <- DedupedTagged]
    ),
    RankedSids = lists:map(fun(ScoredItem) ->
        Key   = maps:remove(<<"score">>, ScoredItem),
        Sid   = maps:get(Key, SidIndex, -1),
        Score = maps:get(<<"score">>, ScoredItem, 0),
        {Sid, Score}
    end, Ranked),

    ValidSids = [S || {S, _} <- RankedSids, S =/= -1],
    ScoresMap = maps:from_list([{integer_to_binary(S), Sc}
                                || {S, Sc} <- RankedSids, S =/= -1]),

    AllSids = [S || {S, _} <- DedupedTagged],
    case length(ValidSids) > 0 andalso
         lists:sort(ValidSids) =:= lists:sort(AllSids) of
        true  ->
            sse_reorder(Req, ValidSids, ScoresMap);
        false ->
            io:format("[emquest] Skipping reorder: ranked ~p / ~p items~n",
                      [length(ValidSids), length(AllSids)]),
            sse(Req, status, <<"Ranking unavailable — showing results as received">>)
    end,

    %% Step 6 — synthesise a prose answer
    sse(Req, status, <<"Generating answer...">>),
    Answer = queen:synthesize(Query, Ranked),
    case Answer of
        <<>> -> ok;
        _    -> sse(Req, answer, Answer)
    end,

    cowboy_req:stream_body(<<>>, fin, Req).

%%====================================================================
%% Streaming disco collection
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Collects results from N spawned disco processes.
%%
%% Accepts the first message that arrives regardless of which PID sent
%% it, so all sub-queries and all disco nodes run truly in parallel.
%% Streams each normalised item to the SSE client immediately.
%%
%% Returns [{Sid :: integer(), RawItem :: map()}].
%% @end
%%--------------------------------------------------------------------
collect_disco_streaming(0, _Req, Acc, _Counter) ->
    lists:reverse(Acc);
collect_disco_streaming(Remaining, Req, Acc, Counter) ->
    receive
        {disco_result, _AnyPid, Tag, Items} ->
            sse(Req, status, iolist_to_binary([
                "Got ", integer_to_binary(length(Items)),
                " result(s) for: \"", Tag, "\""
            ])),
            {NewAcc, NewCounter} = lists:foldl(fun(Item, {A, Ctr}) ->
                NormItem = normalise_item(Item),
                sse_item(Req, Ctr, NormItem),
                {[{Ctr, Item} | A], Ctr + 1}
            end, {Acc, Counter}, Items),
            collect_disco_streaming(Remaining - 1, Req, NewAcc, NewCounter)
    after 8000 ->
        logger:warning("[emquest] disco timeout, ~p process(es) did not respond",
                       [Remaining]),
        lists:reverse(Acc)
    end.

%%====================================================================
%% Deduplication (tagged)
%%====================================================================

deduplicate_tagged(TaggedItems) ->
    {Uniq, _} = lists:foldl(fun({Sid, Item}, {Acc, Seen}) ->
        Props = maps:get(<<"properties">>, Item, #{}),
        Url   = maps:get(<<"url">>, Props, <<>>),
        case Url of
            <<>> ->
                {[{Sid, Item} | Acc], Seen};
            _ ->
                case sets:is_element(Url, Seen) of
                    true  -> {Acc, Seen};
                    false -> {[{Sid, Item} | Acc], sets:add_element(Url, Seen)}
                end
        end
    end, {[], sets:new()}, lists:reverse(TaggedItems)),
    lists:reverse(Uniq).

%%====================================================================
%% Item normalisation
%%====================================================================

normalise_item(Item) ->
    Props = maps:get(<<"properties">>, Item, Item),
    Score = maps:get(<<"score">>, Item, 0),
    Type  = maps:get(<<"type">>,  Item, <<"generic">>),
    Url   = first_defined(Props, [<<"url">>],                      null),
    Label = first_defined(Props, [<<"title">>, <<"label">>,
                                  <<"domain">>],                   <<"Result">>),
    Value = first_defined(Props, [<<"resume">>, <<"value">>,
                                  <<"description">>],              <<>>),
    Ips   = first_defined(Props, [<<"ips">>],                      null),
    Base  = #{<<"label">> => Label, <<"value">> => Value,
              <<"score">> => Score, <<"type">>  => Type},
    case {Url, Ips} of
        {null, [_|_]} -> Base#{<<"ips">>  => Ips};
        {null, _}     -> Base;
        _             -> Base#{<<"url">>  => Url}
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

%% Url is resolved once in run_pipeline and passed down to avoid
%% reading the config file once per spawned process.
fetch_from_disco(Body, Url) ->
    case httpc:request(post,
                       {Url, [], "application/json",
                        binary_to_list(Body)},
                       [{timeout, 10000}], []) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            try {ok, json:decode(iolist_to_binary(RespBody))}
            catch _:_ -> {error, invalid_json} end;
        {ok, {{_, Code, _}, _, _}} -> {error, {http, Code}};
        {error, R}                 -> {error, R}
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

sse_item(Req, Sid, Item) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">> => <<"item">>,
        <<"sid">>  => Sid,
        <<"item">> => Item
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).

sse_reorder(Req, Sids, ScoresMap) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">>   => <<"reorder">>,
        <<"sids">>   => Sids,
        <<"scores">> => ScoresMap
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).
