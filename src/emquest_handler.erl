%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP handler — SSE streaming pipeline.
%%%
%%% Handles two routes:
%%%
%%%   GET  /       → serves `priv/templates/index.html'
%%%   POST /query  → streams results as Server-Sent Events
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

-export([init/2, fetch_from_agent/2]).

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

init(Req0, network) ->
    Path = filename:join([code:priv_dir(emquest), "templates", "network.html"]),
    {Code, Body, CT} = case file:read_file(Path) of
        {ok, Bin} -> {200, Bin, <<"text/html">>};
        {error, R} ->
            logger:error("[emquest] network.html read failed: ~p", [R]),
            {500, <<"Internal Server Error">>, <<"text/plain">>}
    end,
    {ok, cowboy_req:reply(Code, #{<<"content-type">> => CT}, Body, Req0), network};

init(Req0, network_peers) ->
    Peers = try emquest_pop:all_peers() catch _:_ -> [] end,
    PeerList = [begin
        H    = maps:get(host,       P, <<"unknown">>),
        QP   = maps:get(query_port, P, undefined),
        Name = maps:get(name,       P, <<>>),
        #{<<"host">>       => H,
          <<"name">>       => Name,
          <<"query_port">> => case QP of undefined -> null; _ -> QP end,
          <<"routable">>   => QP =/= undefined}
    end || P <- Peers],
    Body = iolist_to_binary(json:encode(PeerList)),
    {ok, cowboy_req:reply(200, #{
        <<"content-type">>  => <<"application/json">>,
        <<"cache-control">> => <<"no-cache">>
    }, Body, Req0), network_peers};

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

    %% Step 1 — expand query into sub-queries.
    sse(Req, status, <<"Expanding query...">>),
    SubQueries = queen:expand(Query),

    %% Step 2 — disco fan-out: one process per (sub-query × disco node).
    Nodes     = queen:disco_nodes(),
    DiscoUrls = [Node ++ "/query" || Node <- Nodes],
    Parent    = self(),
    DiscoPids = [spawn(fun() ->
                    Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
                    Tag  = iolist_to_binary([Q, " @ ", Url]),
                    case fetch_from_disco(Body, Url) of
                        {ok, #{<<"embryo_list">> := Items}} ->
                            Parent ! {disco_result, self(), Tag, Items};
                        {error, R} ->
                            logger:warning("[emquest] disco fail ~s: ~p",
                                           [Tag, R]),
                            Parent ! {disco_result, self(), Tag, []}
                    end
                 end) || Q <- SubQueries, Url <- DiscoUrls],

    %% Step 3 — em_pop fan-out: query vector → top-K peers → direct HTTP.
    %% Runs in parallel with the disco fan-out above.
    QueryVec = em_filter_vec:from_capabilities(SubQueries),
    PopPeers = try emquest_pop:peers_for_query(QueryVec, 10)
               catch
                   exit:{noproc, _}       -> [];  %% emquest_pop not started
                   exit:{timeout, _}      -> [];  %% gen_server call timeout
                   error:badarg           -> []   %% malformed vector (defensive)
               end,
    PopPids  = spawn_pop_workers(SubQueries, PopPeers, Parent),

    %% Report how many sources we are waiting on.
    TotalWorkers = length(DiscoPids) + length(PopPids),
    sse(Req, status, iolist_to_binary([
        "Querying ", integer_to_binary(length(DiscoUrls)),
        " disco + ", integer_to_binary(length(PopPeers)),
        " em_pop peer(s)..."
    ])),

    %% Step 4 — collect all results (disco + em_pop), streaming each item.
    TaggedItems = collect_disco_streaming(TotalWorkers, Req, [], 0),

    %% Step 5 — aggregate: group by URL, score by occurrence + RRF + text match.
    logger:notice("[emquest] ~p result(s) collected (~p workers)",
                  [length(TaggedItems), TotalWorkers]),

    {SortedSids, ScoresMap} = aggregate_and_rank(TaggedItems, SubQueries),
    sse_reorder(Req, SortedSids, ScoresMap),

    cowboy_req:stream_body(<<>>, fin, Req).

%%====================================================================
%% Streaming disco collection
%%====================================================================

%% @private
%% @doc Collect results from `N' spawned disco processes.
%%
%% Waits for `{disco_result, Pid, Tag, Items}' messages from any of
%% the spawned fan-out processes. Accepts messages in arrival order
%% regardless of which process sent them, so all sub-queries and all
%% disco nodes truly run in parallel.
%%
%% Each item is normalised and streamed to the SSE client immediately
%% via `sse_item/3'. If a process does not respond within 8 seconds
%% it is silently dropped.
%%
%% Returns `[{Sid :: non_neg_integer(), RawItem :: map(),
%% RankInSource :: non_neg_integer()}]' in arrival order.
%% @end
-spec collect_disco_streaming(non_neg_integer(), cowboy_req:req(),
                               list(), non_neg_integer()) ->
    [{non_neg_integer(), map(), non_neg_integer()}].
collect_disco_streaming(0, _Req, Acc, _Counter) ->
    lists:reverse(Acc);
collect_disco_streaming(Remaining, Req, Acc, Counter) ->
    receive
        {disco_result, _AnyPid, Tag, Items} ->
            sse(Req, status, iolist_to_binary([
                "Got ", integer_to_binary(length(Items)),
                " result(s) for: \"", Tag, "\""
            ])),
            {NewAcc, NewCounter} = lists:foldl(fun({Rank, Item}, {A, Ctr}) ->
                NormItem = normalise_item(Item),
                sse_item(Req, Ctr, NormItem),
                {[{Ctr, Item, Rank} | A], Ctr + 1}
            end, {Acc, Counter}, lists:zip(lists:seq(0, length(Items) - 1), Items)),
            collect_disco_streaming(Remaining - 1, Req, NewAcc, NewCounter)
    after 8000 ->
        logger:warning("[emquest] disco timeout, ~p process(es) did not respond",
                       [Remaining]),
        lists:reverse(Acc)
    end.

%%====================================================================
%% Aggregation — occurrence count + Reciprocal Rank Fusion
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Aggregate raw results by URL, score by occurrence + RRF + text.
%%
%% Groups all {Sid, Item, RankInSource} triples by dedup key (URL or
%% label).  For each group:
%%   occ  = number of distinct sources that returned this URL
%%   rrf  = sum of 1/(RankInSource + 60) across all occurrences
%%   text = text_score of the representative item (first streamed)
%%   final_score = occ * 10 + rrf * 100 + text
%%
%% Returns {SortedSids, ScoresMap} where:
%%   SortedSids — representative Sid per group, best score first
%%   ScoresMap  — #{<<"Sid">> => FinalScore} for all representatives
%% @end
%%--------------------------------------------------------------------
-spec aggregate_and_rank([{non_neg_integer(), map(), non_neg_integer()}],
                          [binary()]) ->
    {[non_neg_integer()], map()}.
aggregate_and_rank(TaggedItems, SubQueries) ->
    %% Group by dedup key; preserve first-streamed (lowest Sid) as representative.
    Groups = lists:foldl(fun({Sid, Item, Rank}, Acc) ->
        Key = dedup_key(Item),
        Entry = {Sid, Item, Rank},
        maps:update_with(Key, fun(Existing) -> [Entry | Existing] end,
                         [Entry], Acc)
    end, #{}, lists:reverse(TaggedItems)),  %% reverse so foldl keeps lowest Sid first

    %% Score each group.
    Scored = maps:fold(fun(_Key, Group, Acc) ->
        {RepSid, RepItem, _} = hd(Group),
        Occ  = length(Group),
        RRF  = lists:sum([1.0 / (R + 60) || {_, _, R} <- Group]),
        Text = text_score(SubQueries, RepItem),
        Score = Occ * 10 + RRF * 100 + Text,
        [{RepSid, Score} | Acc]
    end, [], Groups),

    %% Sort best score first.
    Sorted     = lists:sort(fun({_, A}, {_, B}) -> A >= B end, Scored),
    SortedSids = [S || {S, _} <- Sorted],
    ScoresMap  = maps:from_list(
        [{integer_to_binary(S), Sc} || {S, Sc} <- Sorted]),
    {SortedSids, ScoresMap}.

%%--------------------------------------------------------------------
%% @private
%% @doc Extract the dedup key from a raw result item.
%%
%% Mirrors the logic previously in deduplicate_tagged/1.
%% @end
%%--------------------------------------------------------------------
-spec dedup_key(map()) -> term().
dedup_key(Item) ->
    Props = maps:get(<<"properties">>, Item, Item),
    Url   = maps:get(<<"url">>, Props, <<>>),
    Label = maps:get(<<"label">>, Item, <<>>),
    case Url of
        <<>> when Label =/= <<>> -> {label, Label};
        <<>>                     -> {unique, erlang:unique_integer()};
        _                        -> {url, Url}
    end.

%%====================================================================
%% Item normalisation
%%====================================================================

%% @private
%% @doc Normalise a raw agent result map into a flat display item.
%%
%% Extracts `url', `label', `value', and `ips' from the result's
%% `properties' map (or the top-level map if no `properties' key
%% exists). Returns a map ready for JSON encoding and delivery to
%% the browser.
%% @end
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

%%--------------------------------------------------------------------
%% @doc POST a query directly to one em_pop agent and return its items.
%%
%% `Url' is the full endpoint, e.g. `"http://agent.lan:9201/agent/query"'.
%% Returns `{ok, [Item]}' on success — Items are the decoded results
%% from the agent's `{"results": [...]}' response body.
%%
%% Returns `{error, Reason}' on any HTTP error, timeout, or bad JSON.
%% @end
%%--------------------------------------------------------------------
-spec fetch_from_agent(binary(), string()) ->
    {ok, [map()]} | {error, term()}.
fetch_from_agent(Body, Url) ->
    case httpc:request(post,
                       {Url, [], "application/json",
                        binary_to_list(Body)},
                       [{timeout, 8000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            try
                #{<<"results">> := Items} = json:decode(RespBody),
                case is_list(Items) of
                    true  -> {ok, Items};
                    false -> {ok, []}
                end
            catch _:_ -> {error, invalid_response} end;
        {ok, {{_, Code, _}, _, _}} -> {error, {http, Code}};
        {error, R}                 -> {error, R}
    end.

%%--------------------------------------------------------------------
%% @doc Spawn one worker process per (sub-query × em_pop peer).
%%
%% Workers send `{disco_result, self(), Tag, Items}' to Parent —
%% the same message pattern as disco workers so `collect_disco_streaming'
%% handles both sources transparently.
%%
%% `Peers' is the list returned by `emquest_pop:peers_for_query/2':
%%   `[{#{host := H, query_port := QP, ...}, Score}]'.
%% @end
%%--------------------------------------------------------------------
-spec spawn_pop_workers([binary()], [{map(), float()}], pid()) -> [pid()].
spawn_pop_workers(SubQueries, Peers, Parent) ->
    [spawn(fun() ->
        H   = binary_to_list(maps:get(host, PeerMap)),
        QP  = maps:get(query_port, PeerMap),
        Url = lists:flatten(
                  io_lib:format("http://~s:~w/agent/query", [H, QP])),
        Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
        Tag  = iolist_to_binary([Q, " @pop ", H, ":", integer_to_list(QP)]),
        case fetch_from_agent(Body, Url) of
            {ok, Items} ->
                Parent ! {disco_result, self(), Tag, Items};
            {error, R} ->
                logger:warning("[emquest] pop agent fail ~s: ~p", [Tag, R]),
                Parent ! {disco_result, self(), Tag, []}
        end
    end)
    || Q <- SubQueries, {PeerMap, _Score} <- Peers].

%%====================================================================
%% Text scoring
%%====================================================================

%% @private
%% @doc Score a raw result item by how many sub-query terms appear in its text.
%%
%% Checks all text fields (title, label, resume, value, description, url)
%% against each lower-cased sub-query. A match anywhere yields +3; missing
%% yields 0. The total is summed across all sub-queries so that items
%% relevant to more sub-terms rank higher.
%%
%% This is intentionally simple — exact substring match, no stemming.
%% It reliably boosts results that contain the literal search term (e.g.
%% "turingdb") over unrelated items from feeds that ignore the query.
%% @end
-spec text_score([binary()], map()) -> non_neg_integer().
text_score([], _Item) -> 0;
text_score(SubQueries, RawItem) ->
    Props = maps:get(<<"properties">>, RawItem, RawItem),
    AllText = lists:foldl(fun(Key, Acc) ->
        case maps:get(Key, Props, <<>>) of
            B when is_binary(B) -> <<Acc/binary, " ", B/binary>>;
            _ -> Acc
        end
    end, <<>>, [<<"title">>, <<"label">>, <<"resume">>,
                <<"value">>, <<"description">>, <<"url">>]),
    Lower = list_to_binary(string:lowercase(binary_to_list(AllText))),
    lists:sum([
        case binary:match(Lower,
                 list_to_binary(string:lowercase(binary_to_list(Q)))) of
            nomatch -> 0;
            _       -> 3
        end
    || Q <- SubQueries, byte_size(Q) > 0]).

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
%% @doc Send a `reorder' SSE event with the final ranked sid list and scores.
%% @end
-spec sse_reorder(cowboy_req:req(), [non_neg_integer()], map()) -> ok.
sse_reorder(Req, Sids, ScoresMap) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">>   => <<"reorder">>,
        <<"sids">>   => Sids,
        <<"scores">> => ScoresMap
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).
