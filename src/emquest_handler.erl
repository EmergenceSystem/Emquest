%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP handler — SSE streaming pipeline.
%%%
%%% Handles two routes registered by {@link emquest_sup}:
%%%
%%% ```
%%% GET  /       → serves priv/templates/index.html
%%% POST /query  → streams results as Server-Sent Events
%%% '''
%%%
%%% === SSE event types ===
%%%
%%% ```
%%% {"type": "status",  "message": "..."}
%%% {"type": "item",    "item": {...}, "sid": N}
%%% {"type": "reorder", "sids": [N,...], "scores": {"N": 0-3, ...}}
%%% {"type": "error",   "message": "..."}
%%% '''
%%%
%%% === Pipeline (POST /query) ===
%%%
%%% ```
%%% 1. queen:expand/1      — split long queries into sub-queries (LLM)
%%% 2. queen:disco_nodes/0 — resolve all configured disco node URLs
%%% 3. Fan-out             — one process per (sub-query × disco node),
%%%                          all running in parallel
%%% 4. Collect             — stream each item to the SSE client as it
%%%                          arrives; 8 s per-process timeout
%%% 5. Deduplicate         — first occurrence by URL wins
%%% 6. Reorder             — always emitted so the browser can remove
%%%                          duplicates that arrived before dedup ran
%%% '''
%%%
%%% === Multi-disco fan-out ===
%%%
%%% `queen:disco_nodes/0' returns the full list of disco HTTP base URLs
%%% (local nodes from `emergence.conf' plus optional remote registry).
%%% The pipeline spawns one process per (sub-query × disco node) so all
%%% sources are queried fully in parallel. Deduplication by URL absorbs
%%% any overlap between nodes or sub-queries.
%%%
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

%% @private
%% @doc Execute the full query pipeline and stream results to the client.
%%
%% Runs synchronously inside the Cowboy request process. Each step
%% sends SSE events to `Req' as it completes. Returns only after the
%% stream is closed with `cowboy_req:stream_body(<<>>, fin, Req)'.
%% @end
-spec run_pipeline(binary(), cowboy_req:req()) -> ok.
run_pipeline(Query, Req) ->
    logger:notice("[emquest] query: ~ts", [Query]),
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

    logger:notice("[emquest] ~p response(s) collected", [length(DedupedTagged)]),

    %% Step 5 — send reorder to deduplicate browser-side (arrival order, no LLM ranking)
    AllSids = [S || {S, _} <- DedupedTagged],
    NeutralScores = maps:from_list([{integer_to_binary(S), 0} || S <- AllSids]),
    sse_reorder(Req, AllSids, NeutralScores),

    cowboy_req:stream_body(<<>>, fin, Req).

%%====================================================================
%% Streaming disco collection
%%====================================================================

%% @private
%% @doc Collect results from `N' spawned disco processes.
%%
%% Waits for `{disco_result, Pid, Tag, Items}' messages from any of
%% the spawned fan-out processes, in arrival order. Each item is
%% normalised and immediately streamed to the SSE client via
%% `sse_item/3'. Processes that do not respond within 8 seconds are
%% silently dropped.
%%
%% Returns `[{Sid :: non_neg_integer(), RawItem :: map()}]' in
%% arrival order.
%% @end
-spec collect_disco_streaming(non_neg_integer(), cowboy_req:req(),
                               list(), non_neg_integer()) ->
    [{non_neg_integer(), map()}].
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

%% @private
%% @doc Deduplicate a list of `{Sid, Item}' pairs by URL.
%%
%% Items without a URL are always kept. Among items sharing the same
%% URL, the first occurrence (lowest Sid, earliest arrival) wins.
%% Preserves arrival order in the output.
%% @end
-spec deduplicate_tagged([{non_neg_integer(), map()}]) ->
    [{non_neg_integer(), map()}].
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

%% @private
%% @doc POST a query to a single disco node and decode the JSON response.
%%
%% `Url' must be a fully-qualified POST endpoint, for example
%% `"http://localhost:8080/query"'. Returns `{ok, Map}' on a 200
%% response with valid JSON, `{error, Reason}' otherwise.
%% @end
-spec fetch_from_disco(binary(), string()) ->
    {ok, map()} | {error, term()}.
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

%% @private
%% @doc Send a `status' or `error' SSE event to the client.
%% @end
-spec sse(cowboy_req:req(), atom(), binary()) -> ok.
sse(Req, Type, Message) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">>    => atom_to_binary(Type, utf8),
        <<"message">> => Message
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).

%% @private
%% @doc Send an `item' SSE event for a single result card.
%% @end
-spec sse_item(cowboy_req:req(), non_neg_integer(), map()) -> ok.
sse_item(Req, Sid, Item) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">> => <<"item">>,
        <<"sid">>  => Sid,
        <<"item">> => Item
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).

%% @private
%% @doc Send a `reorder' SSE event with the final sid list and scores.
%% @end
-spec sse_reorder(cowboy_req:req(), [non_neg_integer()], map()) -> ok.
sse_reorder(Req, Sids, ScoresMap) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">>   => <<"reorder">>,
        <<"sids">>   => Sids,
        <<"scores">> => ScoresMap
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).
