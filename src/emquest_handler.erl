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

-export([init/2, fetch_from_agent/2, fetch_preview/1]).

%% Default trust assigned to em_pop peers that have no recorded trust score.
-define(TRUST_INIT, 0.10).

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

init(Req0, drift) ->
    Path = filename:join([code:priv_dir(emquest), "templates", "drift.html"]),
    {Code, Body, CT} = case file:read_file(Path) of
        {ok, Bin} -> {200, Bin, <<"text/html">>};
        {error, R} ->
            logger:error("[emquest] drift.html read failed: ~p", [R]),
            {500, <<"Internal Server Error">>, <<"text/plain">>}
    end,
    {ok, cowboy_req:reply(Code, #{<<"content-type">> => CT}, Body, Req0), drift};

init(Req0, preview) ->
    QS  = cowboy_req:parse_qs(Req0),
    Url = proplists:get_value(<<"url">>, QS, <<>>),
    {Code, Body} = case fetch_preview(Url) of
        {ok, Desc} ->
            JSON = iolist_to_binary(json:encode(#{<<"description">> => Desc})),
            {200, JSON};
        {error, _} ->
            {200, <<"{\"description\":\"\"}">>}
    end,
    {ok, cowboy_req:reply(Code, #{
        <<"content-type">>                => <<"application/json">>,
        <<"cache-control">>               => <<"max-age=3600">>,
        <<"access-control-allow-origin">> => <<"*">>
    }, Body, Req0), preview};

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
    end;

%% Media: an uploaded image (multipart) or an image URL ({"url":...}) is routed
%% to velora and answered with a raster card (absolute tile URLs). Non-images
%% get 415 "not supported for now". This is the generic upload hook — for now
%% only images, handled by velora.
init(Req0, media) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            CT = cowboy_req:header(<<"content-type">>, Req0, <<>>),
            case binary:match(CT, <<"multipart/form-data">>) of
                nomatch -> media_url(Req0);
                _       -> media_upload(Req0)
            end;
        _ ->
            {ok, cowboy_req:reply(405,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":\"Use POST\"}">>, Req0), media}
    end.

%%====================================================================
%% Media (image -> velora)
%%====================================================================

media_upload(Req0) ->
    case read_upload(Req0) of
        {ok, Filename, Bytes, Req1} ->
            case is_image_ext(Filename) of
                true  -> media_result(Req1, velora_upload_render(Filename, Bytes));
                false -> media_unsupported(Req1)
            end;
        {error, Reason, Req1} ->
            media_err(Req1, 400, Reason)
    end.

media_url(Req0) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case (try json:decode(Body) catch _:_ -> #{} end) of
        #{<<"url">> := Url} when is_binary(Url) ->
            case is_image_ext(Url) of
                true  -> media_result(Req1, velora_filter_render(Url));
                false -> media_unsupported(Req1)
            end;
        _ -> media_err(Req1, 400, missing_url)
    end.

media_result(Req, {ok, Card})     -> {ok, cowboy_req:reply(200, media_ct(), json:encode(Card), Req), media};
media_result(Req, {error, Reason}) -> media_err(Req, 502, Reason).

media_unsupported(Req) ->
    {ok, cowboy_req:reply(415, media_ct(),
        json:encode(#{<<"error">> => <<"only images are supported for now">>}), Req), media}.

media_err(Req, Code, Reason) ->
    {ok, cowboy_req:reply(Code, media_ct(),
        json:encode(#{<<"error">> => media_ebin(Reason)}), Req), media}.

media_ct() -> #{<<"content-type">> => <<"application/json">>}.
media_ebin(B) when is_binary(B) -> B;
media_ebin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

%% Read the first multipart file part; returns {ok, Filename, Bytes, Req}.
read_upload(Req0) ->
    case cowboy_req:read_part(Req0) of
        {ok, Headers, Req1} ->
            case cow_multipart:form_data(Headers) of
                {file, _Field, Filename, _CType} ->
                    {Bytes, Req2} = read_part_all(Req1, <<>>),
                    {ok, Filename, Bytes, Req2};
                _ ->
                    {_, Req2} = read_part_all(Req1, <<>>),
                    read_upload(Req2)
            end;
        {done, Req1} -> {error, no_file, Req1}
    end.

read_part_all(Req0, Acc) ->
    case cowboy_req:read_part_body(Req0) of
        {ok, Data, Req1}   -> {<<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} -> read_part_all(Req1, <<Acc/binary, Data/binary>>)
    end.

is_image_ext(Bin) ->
    L = string:lowercase(iolist_to_binary(Bin)),
    lists:any(fun(Ext) -> binary:match(L, Ext) =/= nomatch end,
              [<<".jpg">>, <<".jpeg">>, <<".png">>, <<".webp">>, <<".gif">>,
               <<".tif">>, <<".tiff">>, <<".jp2">>, <<".bmp">>]).

velora_base()   -> application:get_env(emquest, velora_url, "http://localhost:8081").
velora_filter() -> application:get_env(emquest, velora_filter_url, "http://localhost:9211/agent/query").
tiles_base()    -> list_to_binary(application:get_env(emquest, velora_tiles_base, "https://velora.roques.me")).

%% File path: upload to velora, render, build an absolute-tiles raster card.
velora_upload_render(Filename, Bytes) ->
    {Boundary, MBody} = build_multipart(Filename, Bytes),
    UpCT = "multipart/form-data; boundary=" ++ Boundary,
    case httpc:request(post, {velora_base() ++ "/uploads", [], UpCT, MBody},
                       [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, S, _}, _, UpResp}} when S =:= 200; S =:= 201 ->
            case (try json:decode(UpResp) catch _:_ -> #{} end) of
                #{<<"uri">> := Uri} -> velora_render(Uri);
                _ -> {error, bad_upload_response}
            end;
        {ok, {{_, C, _}, _, _}} -> {error, {upload_http, C}};
        {error, R} -> {error, R}
    end.

velora_render(Uri) ->
    RBody = iolist_to_binary(json:encode(#{<<"uri">> => Uri})),
    case httpc:request(post, {velora_base() ++ "/render",
                              [{"content-type", "application/json"}],
                              "application/json", RBody},
                       [{timeout, 60000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Resp}} ->
            M   = json:decode(Resp),
            Id  = maps:get(<<"id">>, M),
            NZ  = maps:get(<<"maxNativeZoom">>, M, 19),
            {ok, #{<<"type">> => <<"raster">>, <<"id">> => Id,
                   <<"bounds">> => maps:get(<<"bounds">>, M, null),
                   <<"maxNativeZoom">> => NZ,
                   <<"tiles">> => <<(tiles_base())/binary, "/tiles/", Id/binary, "/{z}/{x}/{y}">>}};
        {ok, {{_, C, _}, _, _}} -> {error, {render_http, C}};
        {error, R} -> {error, R}
    end.

%% URL path: route to the velora tiles filter (mesh agent); its card carries
%% relative tiles, rewritten absolute here.
velora_filter_render(Url) ->
    Body = iolist_to_binary(json:encode(#{<<"query">> => Url})),
    case fetch_from_agent(Body, velora_filter()) of
        {ok, [Card | _]} -> {ok, absolute_tiles(Card)};
        {ok, []}         -> {error, no_result};
        {error, R}       -> {error, R}
    end.

absolute_tiles(#{<<"tiles">> := T} = Card) when is_binary(T) ->
    Card#{<<"tiles">> => <<(tiles_base())/binary, T/binary>>};
absolute_tiles(Card) -> Card.

build_multipart(Filename, Bytes) ->
    B  = "----emq" ++ integer_to_list(erlang:unique_integer([positive])),
    FN = binary_to_list(iolist_to_binary(Filename)),
    Body = iolist_to_binary([
        "--", B, "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"", FN, "\"\r\n",
        "Content-Type: application/octet-stream\r\n\r\n",
        Bytes, "\r\n", "--", B, "--\r\n"]),
    {B, Body}.

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
                            Parent ! {disco_result, self(), Tag, Q, Items, 1.0};
                        {error, R} ->
                            logger:warning("[emquest] disco fail ~s: ~p",
                                           [Tag, R]),
                            Parent ! {disco_result, self(), Tag, Q, [], 1.0}
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

    %% Step 5 — aggregate: group by URL, rank by occ + trust-RRF + coverage + vec.
    logger:notice("[emquest] ~p result(s) collected (~p workers)",
                  [length(TaggedItems), TotalWorkers]),

    {SortedSids, ScoresMap} = aggregate_and_rank(TaggedItems, SubQueries, QueryVec),
    sse_reorder(Req, SortedSids, ScoresMap),

    cowboy_req:stream_body(<<>>, fin, Req).

%%====================================================================
%% Streaming disco collection
%%====================================================================

%% @private
%% @doc Collect results from `N' spawned disco processes.
%%
%% Waits for `{disco_result, Pid, Tag, SubQuery, Items, Trust}' messages.
%% SubQuery is the sub-query that produced this batch; Trust is the
%% source trust score (1.0 for configured disco nodes, peer trust for em_pop).
%%
%% Returns `[{Sid, RawItem, RankInSource, SubQuery, Trust}]' in arrival order.
%% @end
-spec collect_disco_streaming(non_neg_integer(), cowboy_req:req(),
                               list(), non_neg_integer()) ->
    [{non_neg_integer(), map(), non_neg_integer(), binary(), float()}].
collect_disco_streaming(0, _Req, Acc, _Counter) ->
    lists:reverse(Acc);
collect_disco_streaming(Remaining, Req, Acc, Counter) ->
    receive
        {disco_result, _AnyPid, Tag, SubQuery, Items, Trust} ->
            sse(Req, status, iolist_to_binary([
                "Got ", integer_to_binary(length(Items)),
                " result(s) for: \"", Tag, "\""
            ])),
            {NewAcc, NewCounter} = lists:foldl(fun({Rank, Item}, {A, Ctr}) ->
                NormItem = normalise_item(Item),
                sse_item(Req, Ctr, NormItem),
                {[{Ctr, Item, Rank, SubQuery, Trust} | A], Ctr + 1}
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
%%   rrf  = sum of 1/(RankInSource + 1 + 60) across all occurrences (1-based RRF, k=60)
%%   text = max text_score across all items in the group
%%   final_score = occ * 10 + rrf * 100 + text
%%
%% Note: occ and rrf are complementary — occ rewards breadth (how many
%% sources found it), rrf rewards rank quality within each source.
%% They can overlap when multiple sub-queries hit the same source, which
%% is acceptable since sub-query coverage is a genuine relevance signal.
%%
%% Returns {SortedSids, ScoresMap} where:
%%   SortedSids — representative Sid per group, best score first
%%   ScoresMap  — #{<<"Sid">> => FinalScore} for all representatives
%% @end
%%--------------------------------------------------------------------
-spec aggregate_and_rank(
        [{non_neg_integer(), map(), non_neg_integer(), binary(), float()}],
        [binary()], binary()) ->
    {[non_neg_integer()], map()}.
aggregate_and_rank(TaggedItems, _SubQueries, QueryVec) ->
    %% Group by dedup key; preserve first-streamed (lowest Sid) as representative.
    Groups = lists:foldl(fun({Sid, Item, Rank, SubQ, Trust}, Acc) ->
        Key   = dedup_key(Item),
        Entry = {Sid, Item, Rank, SubQ, Trust},
        maps:update_with(Key, fun(Existing) -> [Entry | Existing] end,
                         [Entry], Acc)
    end, #{}, lists:reverse(TaggedItems)),  %% reverse so foldl keeps lowest Sid first

    %% Score each group.
    Scored = maps:fold(fun(_Key, Group, Acc) ->
        {RepSid, _RepItem, _, _, _} = hd(Group),

        %% Occurrence breadth — how many source batches returned this URL.
        Occ = length(Group),

        %% Trust-weighted RRF — a trusted source's rank-1 beats an unknown's.
        RRF = lists:sum([Trust / (R + 1 + 60) || {_, _, R, _, Trust} <- Group]),

        %% Sub-query coverage — how many distinct sub-queries this item satisfies.
        SubQs    = sets:from_list([SQ || {_, _, _, SQ, _} <- Group], [{version, 2}]),
        Coverage = sets:size(SubQs),

        %% Semantic vector similarity — item text vs query vector.
        VecScore = lists:max([item_vec_score(QueryVec, I) || {_, I, _, _, _} <- Group]),

        Score = Occ * 10 + RRF * 100 + Coverage * 15 + VecScore * 20,
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
        H     = binary_to_list(maps:get(host, PeerMap)),
        QP    = maps:get(query_port, PeerMap),
        Trust = maps:get(trust, PeerMap, ?TRUST_INIT),
        Url   = lists:flatten(
                    io_lib:format("http://~s:~w/agent/query", [H, QP])),
        Body  = iolist_to_binary(json:encode(#{<<"query">> => Q})),
        Tag   = iolist_to_binary([Q, " @pop ", H, ":", integer_to_list(QP)]),
        case fetch_from_agent(Body, Url) of
            {ok, Items} ->
                Parent ! {disco_result, self(), Tag, Q, Items, Trust};
            {error, R} ->
                logger:warning("[emquest] pop agent fail ~s: ~p", [Tag, R]),
                Parent ! {disco_result, self(), Tag, Q, [], Trust}
        end
    end)
    || Q <- SubQueries, {PeerMap, _Score} <- Peers].

%%====================================================================
%% Text scoring
%%====================================================================

%% @private
%% @doc Compute cosine similarity between the query vector and an item's text.
%%
%% Extracts all text fields from the raw item, vectorises them with
%% `em_filter_vec:from_capabilities/1' (same hash-projection as the routing
%% layer), then returns the dot product of the two unit vectors — which equals
%% cosine similarity since both vectors are L2-normalised.
%%
%% Returns a float in [-1.0, 1.0]; higher means more semantically similar.
%% Returns 0.0 when the item has no extractable text.
%% @end
-spec item_vec_score(binary(), map()) -> float().
item_vec_score(QueryVec, RawItem) ->
    Props = maps:get(<<"properties">>, RawItem, RawItem),
    Words = [V || Key <- [<<"title">>, <<"label">>, <<"resume">>,
                           <<"value">>, <<"description">>],
                  V   <- [maps:get(Key, Props, <<>>)],
                  is_binary(V), byte_size(V) > 0],
    case Words of
        [] -> 0.0;
        _  ->
            ItemVec = em_filter_vec:from_capabilities(Words),
            dot_product(QueryVec, ItemVec)
    end.

%% @private
%% @doc Dot product of two f32 little-endian binary vectors.
%% @end
-spec dot_product(binary(), binary()) -> float().
dot_product(A, B) ->
    FA = [F || <<F:32/float-little>> <= A],
    FB = [F || <<F:32/float-little>> <= B],
    lists:foldl(fun({X, Y}, Acc) -> Acc + X * Y end, 0.0, lists:zip(FA, FB)).

%%====================================================================
%% Preview fetch
%%====================================================================

%% @doc Fetch a URL and extract a meaningful description for drift cards.
%%
%% Two-pass strategy:
%%   Pass 1 — meta tags: og:description, then meta name=description.
%%            Fast; present on most sites but often short or SEO-y.
%%   Pass 2 — body text: concatenate <p> content found inside <article>,
%%            <main>, or anywhere if neither is present. Strips inline tags.
%%            Slower but captures the real article intro.
%%
%% The result with the higher "substance score" (length × non-fluff bonus)
%% is returned, truncated to 320 chars.  Times out in 5 s.
%% @end
-spec fetch_preview(binary()) -> {ok, binary()} | {error, term()}.
fetch_preview(<<>>) -> {error, empty_url};
fetch_preview(Url) ->
    UrlStr = binary_to_list(Url),
    case httpc:request(get, {UrlStr, [{"User-Agent",
                "Mozilla/5.0 (compatible; Emquest/1.0)"}]},
                       [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, best_description(Body)};
        {ok, {{_, Code, _}, _, _}} ->
            {error, {http, Code}};
        {error, R} ->
            {error, R}
    end.

%% @private
%% @doc Pick the more informative of the meta description and the body text.
%% @end
-spec best_description(binary()) -> binary().
best_description(Html) ->
    Meta = extract_meta(Html),
    Body = extract_body_text(Html),
    case substance_score(Meta) >= substance_score(Body) of
        true  -> truncate(Meta, 320);
        false -> truncate(Body, 320)
    end.

%% @private
%% @doc Score a candidate description by length, penalising SEO fluff.
%%
%% Short texts (<60 chars) score 0 so the other candidate wins by default.
%% Common SEO phrases (discover, learn more, click here…) reduce the score.
%% @end
-spec substance_score(binary()) -> non_neg_integer().
substance_score(<<>>) -> 0;
substance_score(B) ->
    Len = byte_size(B),
    case Len < 60 of
        true  -> 0;
        false ->
            Lower = string:lowercase(binary_to_list(B)),
            FluffPhrases = ["discover", "learn more", "click here",
                            "sign up", "subscribe", "cookie", "privacy policy",
                            "all rights reserved", "©"],
            Penalty = lists:sum([5 || P <- FluffPhrases,
                                      string:find(Lower, P) =/= nomatch]),
            max(0, Len - Penalty * 10)
    end.

%% @private
%% @doc Extract og:description or meta name=description from <head>.
%% @end
-spec extract_meta(binary()) -> binary().
extract_meta(Html) ->
    Patterns = [
        <<"property=[\"']og:description[\"'][^>]*content=[\"']([^\"']{20,})[\"']">>,
        <<"content=[\"']([^\"']{20,})[\"'][^>]*property=[\"']og:description[\"']">>,
        <<"name=[\"']description[\"'][^>]*content=[\"']([^\"']{20,})[\"']">>,
        <<"content=[\"']([^\"']{20,})[\"'][^>]*name=[\"']description[\"']">>
    ],
    extract_first_match(Html, Patterns).

%% @private
%% @doc Extract and join leading paragraph text from <article> or <main>.
%%
%% Falls back to any <p> tags in the document if neither landmark is found.
%% Strips inline HTML tags from each paragraph before joining.
%% @end
-spec extract_body_text(binary()) -> binary().
extract_body_text(Html) ->
    %% Prefer semantic landmarks; fall back to full document.
    Region = case extract_region(Html, <<"article">>) of
        <<>> -> case extract_region(Html, <<"main">>) of
            <<>> -> Html;
            M    -> M
        end;
        A -> A
    end,
    Paragraphs = extract_paragraphs(Region),
    join_paragraphs(Paragraphs, <<>>, 0).

%% @private Extract the inner HTML of the first <Tag>…</Tag> block.
-spec extract_region(binary(), binary()) -> binary().
extract_region(Html, Tag) ->
    Pat = <<"<", Tag/binary, "[^>]*>([\\s\\S]*?)</", Tag/binary, ">">>,
    case re:run(Html, Pat, [{capture, [1], binary}, caseless]) of
        {match, [M]} -> M;
        _            -> <<>>
    end.

%% @private Extract text content from all <p> tags, stripping inline tags.
-spec extract_paragraphs(binary()) -> [binary()].
extract_paragraphs(Html) ->
    case re:run(Html, <<"<p[^>]*>([\\s\\S]*?)</p>">>,
                [global, {capture, [1], binary}, caseless]) of
        {match, Groups} ->
            [strip_tags(trim_ws(P)) || [P] <- Groups,
             byte_size(trim_ws(P)) > 40];
        _ -> []
    end.

%% @private Join paragraphs with a space until we have enough text.
-spec join_paragraphs([binary()], binary(), non_neg_integer()) -> binary().
join_paragraphs([], Acc, _) -> Acc;
join_paragraphs(_, Acc, N) when N >= 3 -> Acc;
join_paragraphs([P | Rest], <<>>, N) ->
    join_paragraphs(Rest, P, N + 1);
join_paragraphs([P | Rest], Acc, N) ->
    join_paragraphs(Rest, <<Acc/binary, " ", P/binary>>, N + 1).

%% @private Remove all HTML tags from a binary, collapsing whitespace.
-spec strip_tags(binary()) -> binary().
strip_tags(B) ->
    NoTags = re:replace(B, <<"<[^>]+>">>, <<" ">>, [global, {return, binary}]),
    Collapsed = re:replace(NoTags, <<"\\s+">>, <<" ">>, [global, {return, binary}]),
    trim_ws(Collapsed).

%% @private Return the first match from a list of regex patterns.
-spec extract_first_match(binary(), [binary()]) -> binary().
extract_first_match(_Html, []) -> <<>>;
extract_first_match(Html, [Pat | Rest]) ->
    case re:run(Html, Pat, [{capture, [1], binary}, caseless]) of
        {match, [M]} ->
            Trimmed = trim_ws(M),
            case byte_size(Trimmed) > 20 of
                true  -> Trimmed;
                false -> extract_first_match(Html, Rest)
            end;
        _ -> extract_first_match(Html, Rest)
    end.

trim_ws(B) ->
    re:replace(B, <<"^\\s+|\\s+$">>, <<>>, [global, {return, binary}]).

truncate(B, Max) when byte_size(B) =< Max -> B;
truncate(B, Max) ->
    <<Prefix:Max/binary, _/binary>> = B,
    <<Prefix/binary, "…">>.

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
