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
%%% 1. queen:expand/1      — split long queries into sub-queries
%%%                          (HF topics -> local keywords)
%%% 2. queen:disco_nodes/0 — resolve all configured disco node URLs
%%% 3. Fan-out             — one process per (sub-query × disco node),
%%%                          all running in parallel
%%% 4. Collect             — stream each item to the SSE client as it
%%%                          arrives; 8 s per-process timeout
%%% 5. Deduplicate + rank  — first occurrence by URL wins, scored by
%%%                          `aggregate_and_rank/3'
%%% 6. Reorder             — re-scored by `agent_judge' cross-encoder
%%%                          (`rerank' phase) when `[agents] judge' is
%%%                          on, then always
%%%                          emitted so the browser can remove
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

-export([init/2, fetch_from_agent/2, fetch_from_disco/2, normalise_item/1,
         security_headers/1, internal_exposed/0,
         client_ip/1, response_ok/2, fetch_via_relay/3, cap_items/1]).
-export([trust_tier/1, peer_admin_json/1, is_root_pubkey/1]).

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
    %% index (Terminal Glass) has no inline handlers → script-src 'self';
    %% the app CSP additionally permits the on-device SLM (wasm + model CDN).
    {ok, cowboy_req:reply(Code, security_headers_app(CT), Body, Req0), index};

init(Req0, drift) ->
    Path = filename:join([code:priv_dir(emquest), "templates", "drift.html"]),
    {Code, Body, CT} = case file:read_file(Path) of
        {ok, Bin} -> {200, Bin, <<"text/html">>};
        {error, R} ->
            logger:error("[emquest] drift.html read failed: ~p", [R]),
            {500, <<"Internal Server Error">>, <<"text/plain">>}
    end,
    {ok, cowboy_req:reply(Code, security_headers(CT), Body, Req0), drift};

init(Req0, preview) ->
    QS  = cowboy_req:parse_qs(Req0),
    Url = proplists:get_value(<<"url">>, QS, <<>>),
    {Code, Body} = case emquest_preview:fetch(Url) of
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
    %% Public shell — the topology DATA (/network/peers) is admin-gated below,
    %% so the page loads for anyone but only shows peers to a signed-in admin.
    Path = filename:join([code:priv_dir(emquest), "templates", "network.html"]),
    {Code, Body, CT} = case file:read_file(Path) of
        {ok, Bin} -> {200, Bin, <<"text/html">>};
        {error, R} ->
            logger:error("[emquest] network.html read failed: ~p", [R]),
            {500, <<"Internal Server Error">>, <<"text/plain">>}
    end,
    {ok, cowboy_req:reply(Code, security_headers(CT), Body, Req0), network};

%% /filters - public directory shell (glass). Data from /filters.json.
init(Req0, filters) ->
    Path = filename:join([code:priv_dir(emquest), "templates", "filters.html"]),
    {Code, Body, CT} = case file:read_file(Path) of
        {ok, Bin} -> {200, Bin, <<"text/html">>};
        {error, R} ->
            logger:error("[emquest] filters.html read failed: ~p", [R]),
            {500, <<"Internal Server Error">>, <<"text/plain">>}
    end,
    {ok, cowboy_req:reply(Code, security_headers(CT), Body, Req0), filters};

%% /filters.json - PUBLIC, topology-safe directory of filters (name, tier,
%% role, verified). No host/port/ip/pubkey/id. Banned peers excluded; deduped
%% by name.
init(Req0, filters_json) ->
    Peers = emquest_pop:all_peers_safe(),
    Pub   = [filter_public_json(P) || P <- Peers,
             maps:get(name, P, <<>>) =/= <<>>, not peer_banned(P)],
    Uniq  = maps:values(lists:foldl(
              fun(#{<<"name">> := N} = E, A) -> maps:put(N, E, A) end, #{}, Pub)),
    {ok, cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>,
          <<"cache-control">> => <<"max-age=15">>,
          <<"access-control-allow-origin">> => <<"*">>},
        iolist_to_binary(json:encode(Uniq)), Req0), filters_json};

init(Req0, network_peers) ->
    %% Topology leak surface — require an admin token (same as /admin).
    with_admin(Req0, network_peers, fun(_Name) ->
        PeerList = [begin
            QP = maps:get(query_port, P, undefined),
            #{<<"host">>       => maps:get(host, P, <<"unknown">>),
              <<"name">>       => maps:get(name, P, <<>>),
              <<"query_port">> => case QP of undefined -> null; _ -> QP end,
              <<"routable">>   => QP =/= undefined}
        end || P <- emquest_pop:all_peers_safe()],
        json_nc(Req0, 200, PeerList)
    end);

init(Req0, health) ->
    Peers = emquest_health:status(),
    PJson = [#{<<"name">>    => maps:get(name, P, <<>>),
               <<"host">>    => maps:get(host, P, <<>>),
               <<"port">>    => nn(maps:get(port, P, undefined)),
               <<"alive">>   => maps:get(alive, P, false),
               <<"latency">> => nn(maps:get(latency, P, null)),
               <<"fails">>   => maps:get(fails, P, 0),
               <<"last_ok">> => nn(maps:get(last_ok, P, null))} || P <- Peers],
    Cache = try maps:merge(em_cache_store:health(), em_cache_store:stats())
            catch _:_ -> #{} end,
    Payload = #{<<"peers">>       => PJson,
                <<"peer_count">>  => length(PJson),
                <<"alive_count">> => length([1 || P <- Peers, maps:get(alive, P, false)]),
                <<"cache">>       => Cache},
    Body = iolist_to_binary(json:encode(Payload)),
    {ok, cowboy_req:reply(200, #{
        <<"content-type">>  => <<"application/json">>,
        <<"cache-control">> => <<"no-cache">>
    }, Body, Req0), health};

init(Req0, status) ->
    case internal_exposed() of
        false -> {ok, forbidden(Req0), status};
        true ->
            {ok, cowboy_req:reply(200, security_headers(<<"text/html; charset=utf-8">>),
                status_page(), Req0), status}
    end;

init(Req0, query) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case emquest_ratelimit:allow(client_ip(Req0), 10, 60) of
                false -> too_many(Req0, query);
                true ->
                    {ok, RawBody, Req1} = cowboy_req:read_body(Req0),
                    handle_query(RawBody, Req1),
                    {ok, Req1, query}
            end;
        _ ->
            bad_method(Req0, query)
    end;

%% Media: an uploaded image (multipart) or an image URL ({"url":...}) is routed
%% to velora and answered with a raster card (absolute tile URLs). Non-images
%% get 415 "not supported for now". This is the generic upload hook — for now
%% only images, handled by velora.
init(Req0, media) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> emquest_media:media_post(Req0);
        _ ->
            bad_method(Req0, media)
    end;
%% GET /media/prepare/:id — proxy velora's async prepare poll so the browser can
%% poll here (same origin) instead of us blocking the /media request open for the
%% whole warp. Returns {status:processing} | a done raster card | {status:error}.
init(Req0, media_prepare) ->
    emquest_media:prepare(Req0, cowboy_req:binding(id, Req0));
init(Req0, stt) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case emquest_ratelimit:allow(client_ip(Req0), 5, 60) of
                false -> too_many(Req0, stt);
                true  -> emquest_media:stt_do(Req0)
            end;
        _ ->
            bad_method(Req0, stt)
    end;

%% /admin — static shell page (ungated shell; the DATA endpoints below are gated).
init(Req0, admin_index) ->
    Path = filename:join([code:priv_dir(emquest), "templates", "admin.html"]),
    {Code, Body, CT} = case file:read_file(Path) of
        {ok, Bin} -> {200, Bin, <<"text/html">>};
        {error, _} -> {500, <<"admin.html missing">>, <<"text/plain">>}
    end,
    {ok, cowboy_req:reply(Code, security_headers(CT), Body, Req0), admin_index};

%% /admin/me — returns the authenticated admin's name (for the UI to greet
%% + auto-recognize a returning admin whose token is already in IndexedDB).
init(Req0, admin_me) ->
    with_admin(Req0, admin_me, fun(Name) ->
        json_nc(Req0, 200, #{<<"name">> => Name})
    end);

%% /admin/nav — gated HTML fragment: the admin-only nav links. Returned ONLY to
%% an authenticated admin, so the public page source never contains them; the JS
%% injects the result into the header. (The endpoints themselves are the real
%% gate; this just avoids advertising the admin surface in the static HTML.)
init(Req0, admin_nav) ->
    with_admin(Req0, admin_nav, fun(_Name) ->
        Frag = unicode:characters_to_binary(
                 "<a href=\"/network\" class=\"network-link\">network \x{2197}</a>"
                 "<a href=\"/admin\" class=\"network-link\">admin \x{2197}</a>"),
        cowboy_req:reply(200,
            #{<<"content-type">> => <<"text/html; charset=utf-8">>,
              <<"cache-control">> => <<"no-cache">>},
            Frag, Req0)
    end);

%% /admin/peers — gated JSON peer list with trust tier + banned flag.
init(Req0, admin_peers) ->
    with_admin(Req0, admin_peers, fun(_Name) ->
        List = [peer_admin_json(P) || P <- emquest_pop:all_peers_safe()],
        json_nc(Req0, 200, List)
    end);

%% /admin/reports - gated JSON: filters by report count (moderation queue).
init(Req0, admin_reports) ->
    with_admin(Req0, admin_reports, fun(_Name) ->
        Top = try emquest_reports:top(100) catch _:_ -> [] end,
        json_nc(Req0, 200, Top)
    end);

%% /report - public: a viewer flags a bad result from a filter. Rate-limited.
init(Req0, report) ->
    case emquest_ratelimit:allow(client_ip(Req0), 20, 60) of
        false -> {ok, cowboy_req:reply(429, #{}, <<"rate limited">>, Req0), report};
        true ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case (catch json:decode(Body)) of
                #{<<"signer_id">> := Sid} = M when is_binary(Sid) ->
                    Reason = maps:get(<<"reason">>, M, <<>>),
                    Url    = maps:get(<<"url">>, M, <<>>),
                    catch emquest_reports:report(Sid, Reason, Url),
                    {ok, cowboy_req:reply(200,
                        #{<<"content-type">> => <<"application/json">>},
                        <<"{\"ok\":true}">>, Req1), report};
                _ ->
                    {ok, cowboy_req:reply(400,
                        #{<<"content-type">> => <<"application/json">>},
                        <<"{\"error\":\"signer_id required\"}">>, Req1), report}
            end
    end;

init(Req0, admin_ban)   -> admin_action(Req0, ban);
init(Req0, admin_unban) -> admin_action(Req0, unban);
init(Req0, admin_trust) -> admin_action(Req0, trust).

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
    case (catch em_cache:get_from_cache(Query)) of
        {ok, Cached} when is_list(Cached), Cached =/= [] ->
            logger:notice("[emquest] cache hit: ~ts (~p items)",
                          [Query, length(Cached)]),
            sse(Req, status, <<"Cached results">>),
            replay_cached(Cached, Req),
            cowboy_req:stream_body(<<>>, fin, Req);
        _ ->
            run_pipeline_full(Query, Req)
    end.

run_pipeline_full(Query, Req) ->
    logger:notice("[emquest] query: ~ts", [Query]),

    %% Step 1 — expand query into sub-queries (HF topics ->
    %% local_keywords; the original query is always kept first).
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
    %%
    %% Peer selection goes through the meta-agent registry's `select'
    %% phase first (`agent_router', semantic routing by meaning via
    %% hf_topics embeddings). When the Router is off, hf_topics is down,
    %% or it has nothing useful to offer, it returns `skip' and `Ctx1'
    %% below has no `peers' key — we then fall back to the exact
    %% pre-meta-agent behaviour: hash-cosine `peers_for_query/2' plus the
    %% always-on media-bank filters.
    QueryVec = em_filter_vec:from_capabilities(SubQueries),
    Ctx0 = #{query => Query, subqueries => SubQueries},
    Ctx1 = em_agent:run_phase(select, Ctx0),
    PopPeers = case Ctx1 of
        #{peers := RoutedPeers} ->
            RoutedPeers;
        _ ->
            PopPeers0 = try emquest_pop:peers_for_query(QueryVec, 20)
                        catch
                            exit:{noproc, _}       -> [];  %% emquest_pop not started
                            exit:{timeout, _}      -> [];  %% gen_server call timeout
                            error:badarg           -> []   %% malformed vector (defensive)
                        end,
            %% Always include the media-bank filters so image/audio/video
            %% results appear without the user having to type "photo"/
            %% "video" in the query.
            ensure_media_peers(PopPeers0)
    end,
    LivePeers = emquest_health:filter_live(PopPeers),
    PopPids  = spawn_pop_workers(SubQueries, LivePeers, Parent),

    %% Report how many sources we are waiting on.
    TotalWorkers = length(DiscoPids) + length(PopPids),
    sse(Req, status, iolist_to_binary([
        "Querying ", integer_to_binary(length(DiscoUrls)),
        " disco + ", integer_to_binary(length(PopPeers)),
        " em_pop peer(s)..."
    ])),

    %% Step 4 — collect all results (disco + em_pop), streaming each item.
    TaggedItems = collect_disco_streaming(TotalWorkers, Req, Query, QueryVec),

    %% Step 5 — aggregate: group by URL, rank by occ + trust-RRF + coverage + vec.
    logger:notice("[emquest] ~p result(s) collected (~p workers)",
                  [length(TaggedItems), TotalWorkers]),

    {SortedSids, ScoresMap} = aggregate_and_rank(Query, TaggedItems, QueryVec),

    %% Step 6 — cross-encoder re-rank of the top-N via the meta-agent
    %% registry's `rerank' phase (`agent_judge'). `TaggedItems' has one
    %% entry per streamed sid (`Sid' is the running counter assigned in
    %% `collect_disco_streaming/4', globally unique), so it doubles as
    %% the sid -> raw item lookup the Judge needs for title/url/resume.
    %% When the Judge is off, the HF reranker is down/slow, or its
    %% output doesn't parse, `run_phase/2' returns `skip' and
    %% `CtxRerank' below has no `sortedsids' key — we fall back to the
    %% ranking `aggregate_and_rank/3' already produced.
    ItemsBySid = maps:from_list(
        [{Sid, Item} || {Sid, Item, _Rank, _SubQ, _Trust} <- TaggedItems]),
    sse(Req, status, <<"Reranking results...">>),
    CtxRerank = em_agent:run_phase(rerank, #{
        query      => Query,
        sortedsids => SortedSids,
        scores     => ScoresMap,
        items      => ItemsBySid
    }),
    {FinalSids, FinalScores} = case CtxRerank of
        #{sortedsids := JudgedSids} when is_list(JudgedSids), JudgedSids =/= [] ->
            {JudgedSids, maps:get(scores, CtxRerank, ScoresMap)};
        _ ->
            {SortedSids, ScoresMap}
    end,
    FinalSids2 = apply_mmr(FinalSids, maps:get(embeddings, CtxRerank, #{})),
    sse_reorder(Req, FinalSids2, FinalScores),
    maybe_cache(Query, FinalSids2, ItemsBySid),

    cowboy_req:stream_body(<<>>, fin, Req).

%% @private Diversify the head that has embeddings (MMR); append the rest.
apply_mmr(Sids, Emb) when map_size(Emb) > 0, is_list(Sids) ->
    case mmr_on() of
        false -> Sids;
        true ->
            {Head, Tail} = lists:split(min(length(Sids), map_size(Emb)), Sids),
            emquest_rank:mmr(Head, Emb, emquest_rank:mmr_lambda()) ++ Tail
    end;
apply_mmr(Sids, _Emb) -> Sids.

%% @private [rank] mmr on/off, default on.
mmr_on() -> emconf:get_bool("rank", "mmr", true).

%% @private
%% @doc Replay a cached, final-ordered item list as the SSE stream a
%% live query would produce: each item, then a reorder fixing the order.
replay_cached(Items, Req) ->
    N = lists:foldl(fun(Item, Ctr) ->
                        sse_item(Req, Ctr, Item), Ctr + 1
                    end, 0, Items),
    sse_reorder(Req, lists:seq(0, N - 1), #{}).

%% @private
%% @doc Store the final ranked results under the query (10 min TTL).
%% Empty result sets are skipped so failures are never cached.
maybe_cache(_Query, [], _ItemsBySid) -> ok;
maybe_cache(Query, FinalSids, ItemsBySid) ->
    Items = [normalise_item(maps:get(Sid, ItemsBySid, #{})) || Sid <- FinalSids],
    _ = (catch em_cache:put_in_cache(Query, Items, 600)),
    ok.

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
%% Cold-query fan-out cutoff. Rather than wait the full per-agent HTTP
%% budget for every worker, once a quorum has answered the stragglers get
%% only a short grace, capped by a hard overall deadline — one slow filter
%% no longer drags the whole query to the 8s timeout.
-define(COLLECT_HARD_MS,  8000).
-define(COLLECT_GRACE_MS, 1200).
-define(COLLECT_QUORUM,   0.75).
-define(PROGRESSIVE_MS,   700).

-spec collect_disco_streaming(non_neg_integer(), cowboy_req:req(),
                               binary(), binary()) ->
    [{non_neg_integer(), map(), non_neg_integer(), binary(), float()}].
collect_disco_streaming(Total, Req, Query, QueryVec) ->
    Now = erlang:monotonic_time(millisecond),
    collect_loop(Total, Total, Req, [], 0, Now, undefined, Query, QueryVec, Now).

collect_loop(0, _Total, _Req, Acc, _Counter, _Start, _QAt, _Q, _QVec, _LastEmit) ->
    lists:reverse(Acc);
collect_loop(Remaining, Total, Req, Acc, Counter, Start, QAt0, Query, QVec, LastEmit) ->
    Received = Total - Remaining,
    Now      = erlang:monotonic_time(millisecond),
    HardLeft = max(0, ?COLLECT_HARD_MS - (Now - Start)),
    QuorumMet = Total > 0 andalso Received >= trunc(Total * ?COLLECT_QUORUM),
    QAt = case {QuorumMet, QAt0} of {true, undefined} -> Now; _ -> QAt0 end,
    Wait = case QAt of
               undefined -> HardLeft;
               _ -> max(0, min(HardLeft, (QAt + ?COLLECT_GRACE_MS) - Now))
           end,
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
            NewLast = maybe_progressive(Req, NewAcc, Query, QVec, LastEmit, Now),
            collect_loop(Remaining - 1, Total, Req, NewAcc, NewCounter, Start,
                         QAt, Query, QVec, NewLast)
    after Wait ->
        (Remaining > 0) andalso
            logger:notice("[emquest] collect cutoff: ~p/~p worker(s) pending "
                          "after ~pms", [Remaining, Total, Now - Start]),
        lists:reverse(Acc)
    end.

%% @private Emit a light progressive reorder at most every ?PROGRESSIVE_MS,
%% re-scoring the accumulated items with the fast hybrid scorer (no hf).
maybe_progressive(Req, Acc, Query, QVec, LastEmit, Now) ->
    case (Now - LastEmit) >= ?PROGRESSIVE_MS andalso progressive_on() of
        true ->
            case catch emquest_rank:rank(Query, lists:reverse(Acc), QVec) of
                {Sids, Scores} when is_list(Sids), Sids =/= [] ->
                    sse_reorder(Req, Sids, Scores, false);
                _ -> ok
            end,
            Now;
        false ->
            LastEmit
    end.

%% @private [rank] progressive on/off, default on.
progressive_on() -> emconf:get_bool("rank", "progressive", true).

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
-spec aggregate_and_rank(binary(), list(), binary()) ->
    {[non_neg_integer()], map()}.
aggregate_and_rank(Query, TaggedItems, QueryVec) ->
    emquest_rank:rank(Query, TaggedItems, QueryVec).

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
    Base0 = #{<<"label">> => cap(Label, 256),
              <<"value">> => cap(Value, 2048),
              <<"score">> => Score, <<"type">>  => Type,
              <<"source_id">> => maps:get(<<"__source_id">>, Item, null),
              <<"source">>    => maps:get(<<"__source">>,    Item, null)},
    Base1 = add_media(Base0, Props),
    Base  = case maps:get(<<"doc_type">>, Props, undefined) of
                D when is_binary(D), byte_size(D) > 0 -> Base1#{<<"doc_type">> => D};
                _ -> Base1
            end,
    case {safe_url(Url), Ips} of
        {null, [_|_]} -> Base#{<<"ips">>  => Ips};
        {null, _}     -> Base;
        {SafeUrl, _}  -> Base#{<<"url">>  => SafeUrl}
    end.

%% @private Copy media fields into the item when the embryo declares a media_type.
%% Non-media embryos are returned unchanged. URL-shaped fields are scheme-
%% filtered (http/https only); text fields are length-capped. Not HTML-escaped
%% here — the browser renderers (emergence.js/drift.js/network.js) escape every
%% field via escHtml/escAttr before innerHTML, which is the real XSS boundary;
%% escaping again here double-escapes (e.g. "AT&T" -> "AT&amp;T").
add_media(Base, Props) ->
    case first_defined(Props, [<<"media_type">>], null) of
        null -> Base;
        MType ->
            UrlKeys  = [<<"thumbnail">>, <<"media_url">>, <<"source">>],
            TextKeys = [<<"duration">>, <<"license">>, <<"author">>],
            Acc0 = Base#{<<"media_type">> => MType},
            Acc1 = lists:foldl(
              fun(K, Acc) ->
                  case maps:get(K, Props, undefined) of
                      U when is_binary(U) ->
                          case safe_url(U) of
                              null -> Acc;
                              S    -> Acc#{K => S}
                          end;
                      _ -> Acc
                  end
              end, Acc0, UrlKeys),
            lists:foldl(
              fun(K, Acc) ->
                  case maps:get(K, Props, undefined) of
                      undefined -> Acc;
                      null      -> Acc;
                      V when is_binary(V) -> Acc#{K => cap(V, 256)};
                      V         -> Acc#{K => V}
                  end
              end, Acc1, TextKeys)
    end.

first_defined(_Props, [], Default) -> Default;
first_defined(Props, [Key | Rest], Default) ->
    case maps:get(Key, Props, undefined) of
        undefined -> first_defined(Props, Rest, Default);
        null      -> first_defined(Props, Rest, Default);
        V         -> V
    end.

%% @private Return the URL only if scheme is http/https, else null.
safe_url(null) -> null;
safe_url(U) when is_binary(U) ->
    case emquest_safeurl:check_scheme(U) of
        ok -> U;
        _  -> null
    end;
safe_url(_) -> null.

%% @private Truncate an over-long binary field on a UTF-8 character boundary.
cap(B, Max) when is_binary(B), byte_size(B) > Max ->
    trim_incomplete_utf8(binary:part(B, 0, Max));
cap(B, _) -> B.

%% @private Drop a trailing partial UTF-8 sequence left by a byte-offset cut.
trim_incomplete_utf8(B) ->
    case unicode:characters_to_binary(B, utf8, utf8) of
        Bin when is_binary(Bin) -> Bin;
        {incomplete, Valid, _}  -> Valid;
        {error, Valid, _}       -> Valid
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
    case emquest_safeurl:safe_post(list_to_binary(Url), [], "application/json",
                                   Body, [{timeout, 10000}]) of
        {ok, RespBody} ->
            try {ok, json:decode(iolist_to_binary(RespBody))}
            catch _:_ -> {error, invalid_json} end;
        {error, R} -> {error, R}
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
agent_query_url(H, 443, BP) ->
    lists:flatten(io_lib:format("https://~s~s/agent/query", [H, BP]));
agent_query_url(H, QP, BP) ->
    lists:flatten(io_lib:format("http://~s:~w~s/agent/query", [H, QP, BP])).

em_auth_headers() ->
    case application:get_env(em_filter, auth_token, undefined) of
        undefined -> [];
        Tok -> [{"authorization", "Bearer " ++ binary_to_list(Tok)}]
    end.

fetch_from_agent(Body, Url) ->
    case emquest_safeurl:safe_post(list_to_binary(Url), em_auth_headers(),
                                   "application/json", Body, [{timeout, 8000}]) of
        {ok, RespBody} -> parse_agent_response(RespBody);
        {error, R} -> {error, R}
    end.

%% @doc Decode a filter/relay JSON response body of the shape
%% `{"results": [...], "signer_id": .., "signature": ..}' and verify its
%% signature via `response_ok/2'. Shared by the direct-agent fetch
%% (`fetch_from_agent/2') and the relay fetch (`fetch_via_relay/3') — the
%% em_disco `/relay/query' endpoint round-trips the filter's own signed
%% result frame unchanged, so both paths see an identical body shape.
-spec parse_agent_response(binary()) -> {ok, [map()]} | {error, term()}.
parse_agent_response(RespBody) ->
    try
        #{<<"results">> := Items0} = RespMap = json:decode(RespBody),
        Items = case is_list(Items0) of
            true  -> Items0;
            false -> []
        end,
        case response_ok(RespMap, Items) of
            true  -> {ok, cap_items(Items)};
            false -> {error, bad_signature}
        end
    catch _:_ -> {error, invalid_response} end.

%% @doc Cap items accepted from one filter response (anti-flood from an
%% untrusted 3rd-party filter). Applied AFTER signature verification so it
%% never invalidates a signature over the full list. Config
%% `emquest, filter_max_items` (default 200).
-spec cap_items([map()]) -> [map()].
cap_items(Items) ->
    Max = application:get_env(emquest, filter_max_items, 200),
    lists:sublist(Items, Max).

%% @doc `emquest, relay_hub_http_port' — the em_disco hub's Cowboy HTTP
%% listener port that serves `/relay/query' (default 9080, matching
%% `em_disco''s own `http_port' default). `#peer{}'/`PeerMap' carries no
%% dedicated HTTP-port field for the hub role, so this is a fixed/
%% configurable convention rather than something gossiped per-peer.
-spec relay_hub_http_port() -> pos_integer().
relay_hub_http_port() ->
    application:get_env(emquest, relay_hub_http_port, 9080).

%% @doc Resolve the relay hub peer advertising `RelayViaId' (the raw,
%% already-decoded peer id from a leaf's `relay_via' field) by scanning
%% the live peer table. `undefined' when the hub is not currently known
%% (unknown/unreachable relay_via — caller treats this as a peer error).
-spec find_relay_hub(binary()) -> map() | undefined.
find_relay_hub(RelayViaId) when is_binary(RelayViaId) ->
    Peers = emquest_pop:all_peers_safe(),
    case [P || P <- Peers, maps:get(id, P, undefined) =:= RelayViaId] of
        [Hub | _] -> Hub;
        []        -> undefined
    end.

%% @doc POST a query to `PeerId''s relay hub (`/relay/query') on its
%% behalf — used when the peer itself exposes no direct `query_port'.
%% Parses and verifies the response through the same
%% `parse_agent_response/1' path as a direct agent fetch: the hub
%% round-trips the filter's own signed result frame unchanged, so no
%% verify logic is duplicated here.
-spec fetch_via_relay(binary(), map(), term()) -> {ok, [map()]} | {error, term()}.
fetch_via_relay(PeerId, HubPeerMap, Query) ->
    HubHost = binary_to_list(maps:get(host, HubPeerMap, <<>>)),
    Url = lists:flatten(io_lib:format("http://~s:~w/relay/query",
                                       [HubHost, relay_hub_http_port()])),
    Body = iolist_to_binary(json:encode(#{<<"peer_id">> => base64:encode(PeerId),
                                           <<"query">>   => Query})),
    case emquest_safeurl:safe_post(list_to_binary(Url), em_auth_headers(),
                                   "application/json", Body, [{timeout, 8000}]) of
        {ok, RespBody} -> parse_agent_response(RespBody);
        {error, R} -> {error, R}
    end.

%% @doc Whether an unsigned filter response is rejected. Default false
%% (optional phase): accept unsigned until all filters are upgraded to sign.
-spec require_signatures() -> boolean().
require_signatures() ->
    application:get_env(emquest, require_signatures, false) =:= true.

%% @doc Verify a filter response's signature (if present) against the signer's
%% bound pubkey. Returns true = keep, false = drop.
%% - signature + signer_id present, pubkey bound, sig valid   -> true
%% - signature present but invalid / signer unknown           -> false (drop)
%% - no signature: require_signatures() ? false : true
-spec response_ok(map(), list()) -> boolean().
response_ok(RespMap, Items) ->
    case {maps:get(<<"signature">>, RespMap, undefined),
          maps:get(<<"signer_id">>, RespMap, undefined)} of
        {Sig, SignerId} when is_binary(Sig), is_binary(SignerId) ->
            case {decode_b64(SignerId), decode_b64(Sig)} of
                {Id, SigBin} when is_binary(Id), is_binary(SigBin) ->
                    case catch em_pop_store:get_pubkey(Id) of
                        Pub when is_binary(Pub) ->
                            %% We CAN verify: a failed check means tampering or a
                            %% canonical-format mismatch -> always drop, even in
                            %% optional mode.
                            em_pop_crypto:verify(
                                em_pop_crypto:canonical_response(Items), SigBin, Pub);
                        _ ->
                            %% Signer unknown (pubkey not propagated yet): we
                            %% cannot verify. Tolerate during the optional phase,
                            %% drop only when signatures are enforced.
                            not require_signatures()
                    end;
                _ ->
                    %% Malformed signature fields: cannot verify -> tolerate
                    %% unless enforcing.
                    not require_signatures()
            end;
        _ -> not require_signatures()
    end.

%% Only ever called with binaries (see response_ok/2's guards).
decode_b64(B) when is_binary(B) ->
    case catch base64:decode(B) of D when is_binary(D) -> D; _ -> error end.

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
%% @private
%% @doc Append the media-bank filters (images/audio/video) to the hash-selected
%% peer set, so a plain query like "f40" also reaches them. Deduplicated by
%% endpoint; media filters already selected are not added twice.
ensure_media_peers(Selected) ->
    agent_router:with_media(Selected, emquest_pop:all_peers_safe()).

-spec spawn_pop_workers([binary()], [{map(), float()}], pid()) -> [pid()].
spawn_pop_workers(SubQueries, Peers, Parent) ->
    [spawn(fun() ->
        Trust = maps:get(trust, PeerMap, ?TRUST_INIT),
        Id    = maps:get(id, PeerMap, undefined),
        Name  = maps:get(name, PeerMap, <<>>),
        {Tag, FetchResult} = dispatch_pop_worker(Q, PeerMap),
        case FetchResult of
            {ok, Items} ->
                case Items of
                    [_|_] when is_binary(Id) -> catch emquest_pop:credit(Id);
                    _ -> ok
                end,
                Parent ! {disco_result, self(), Tag, Q, stamp_source(Items, Id, Name), Trust};
            {error, R} ->
                (is_binary(Id) andalso catch emquest_pop:penalize(Id)),
                logger:warning("[emquest] pop agent fail ~s: ~p", [Tag, R]),
                Parent ! {disco_result, self(), Tag, Q, [], Trust}
        end
    end)
    || Q <- SubQueries, {PeerMap, _Score} <- Peers].

%% @private Stamp each result with its source filter id (base64) + name, so
%% the browser can attribute and report it. Non-map items and unbound-id
%% sources pass through untouched.
stamp_source(Items, Id, Name) when is_binary(Id) ->
    Sid = base64:encode(Id),
    [I#{<<"__source_id">> => Sid, <<"__source">> => Name} || I <- Items];
stamp_source(Items, _Id, _Name) -> Items.

%% @private
%% @doc Build the `{Tag, FetchResult}' pair for one (sub-query, peer)
%% worker. A peer with a direct `query_port' is queried over HTTP as
%% before. A peer with no direct port (`query_port' is `null' — see
%% `em_pop_node:peer_to_map/1' — or absent) but a bound `relay_via' is
%% routed through that hub's `/relay/query' instead. Any other
%% combination (no port, no relay, or an unresolvable/unreachable hub)
%% is treated as a peer error: skipped with an `{error, _}' result so
%% the caller penalizes it exactly like a failed direct fetch.
dispatch_pop_worker(Q, PeerMap) ->
    H  = binary_to_list(maps:get(host, PeerMap, <<>>)),
    BP = binary_to_list(maps:get(base_path, PeerMap, <<>>)),
    Id = maps:get(id, PeerMap, undefined),
    case maps:get(query_port, PeerMap, undefined) of
        QP when is_integer(QP) ->
            Url  = lists:flatten(agent_query_url(H, QP, BP)),
            Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
            Tag  = iolist_to_binary([Q, " @pop ", H, ":", integer_to_list(QP)]),
            {Tag, fetch_from_agent(Body, Url)};
        _NoDirectPort ->
            case decode_relay_via(maps:get(relay_via, PeerMap, undefined)) of
                RelayViaId when is_binary(RelayViaId) ->
                    Tag = iolist_to_binary([Q, " @relay ", H]),
                    case find_relay_hub(RelayViaId) of
                        Hub when is_map(Hub), is_binary(Id) ->
                            {Tag, fetch_via_relay(Id, Hub, Q)};
                        _ ->
                            {Tag, {error, relay_hub_unknown}}
                    end;
                undefined ->
                    Tag = iolist_to_binary([Q, " @pop ", H, ":unroutable"]),
                    {Tag, {error, unroutable}}
            end
    end.

%% @private Decode a peer map's `relay_via' (`null' | base64 binary |
%% `undefined') to the hub's raw id, or `undefined' when the peer is not
%% relayed / the field is malformed.
decode_relay_via(null) -> undefined;
decode_relay_via(undefined) -> undefined;
decode_relay_via(B) when is_binary(B) ->
    case catch base64:decode(B) of
        D when is_binary(D) -> D;
        _ -> undefined
    end.

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
%% (item_vec_score/dot_product moved into emquest_rank as hash_vec/dot_prod)

%%====================================================================
%% SSE helpers
%%====================================================================

%% @private
%% @doc Send a `status' or `error' SSE event to the client.
%% @end
%% @private
nn(undefined) -> null;
nn(V)         -> V.

%% @doc Whether internal topology routes (/network, /network/peers, /status)
%% are served. Off by default — they leak mesh topology. Enable for internal
%% access only (tailscale / admin), never on the public tunnel.
-spec internal_exposed() -> boolean().
internal_exposed() ->
    application:get_env(emquest, expose_internal, false) =:= true.

%% @private 403 JSON reply for gated routes.
forbidden(Req) ->
    cowboy_req:reply(403,
        #{<<"content-type">> => <<"application/json">>},
        <<"{\"error\":\"not found\"}">>, Req).

%% @doc Real client IP: the Cloudflare `cf-connecting-ip' header when present
%% (Emquest sits behind the tunnel), else the direct peer address.
-spec client_ip(cowboy_req:req()) -> binary().
client_ip(Req) ->
    case cowboy_req:header(<<"cf-connecting-ip">>, Req, undefined) of
        undefined ->
            {IP, _Port} = cowboy_req:peer(Req),
            list_to_binary(inet:ntoa(IP));
        Ip -> Ip
    end.

%%====================================================================
%% Admin console
%%====================================================================

%% @private Extract the bearer token and authenticate the admin. Returns
%% {ok, Name} or {error, _} to short-circuit with a 401.
admin_auth(Req) ->
    Tok = case cowboy_req:header(<<"authorization">>, Req, undefined) of
              <<"Bearer ", T/binary>> -> T;
              _ -> undefined
          end,
    emquest_admin:authenticate(Tok, client_ip(Req)).

%% @private Run `Fun(Name)' for an authenticated admin (it returns the
%% replied Req), else answer 401. Collapses the identical auth gate that
%% every gated admin route used to inline. `Tag' is the Cowboy state.
with_admin(Req, Tag, Fun) ->
    case admin_auth(Req) of
        {ok, Name} -> {ok, Fun(Name), Tag};
        _          -> {ok, unauthorized(Req), Tag}
    end.

%% @private No-cache JSON reply, returning the replied Req.
json_nc(Req, Code, Term) ->
    cowboy_req:reply(Code,
        #{<<"content-type">> => <<"application/json">>,
          <<"cache-control">> => <<"no-cache">>},
        iolist_to_binary(json:encode(Term)), Req).

%% @private 401 JSON reply for a missing/invalid admin token.
unauthorized(Req) ->
    cowboy_req:reply(401, #{<<"content-type">> => <<"application/json">>},
        <<"{\"error\":\"unauthorized\"}">>, Req).

%% @private Build the admin JSON view of one peer map. `emquest_pop:all_peers/0'
%% returns maps built by `em_pop_node:peer_to_map/1', which always carries
%% atom keys `id' (16-byte binary) and `trust' (float) — no binary-key
%% fallback is needed, but it's kept defensively cheap in case that shape
%% ever changes.
peer_admin_json(P) ->
    Id    = maps:get(id, P, maps:get(<<"id">>, P, undefined)),
    Name  = maps:get(name, P, maps:get(<<"name">>, P, <<>>)),
    Trust = maps:get(trust, P, maps:get(<<"trust">>, P, 0.0)),
    QP    = maps:get(query_port, P, maps:get(<<"query_port">>, P, undefined)),
    PK    = maps:get(pubkey, P, undefined),
    LS    = maps:get(last_seen, P, null),
    Role  = maps:get(role, P, undefined),
    PkB64 = case PK of B when is_binary(B) -> base64:encode(B); _ -> undefined end,
    IdB64 = case Id of undefined -> null; _ when is_binary(Id) -> base64:encode(Id); _ -> null end,
    #{<<"id">>    => IdB64,
      <<"name">>  => Name,
      <<"trust">> => Trust,
      <<"tier">>  => trust_tier(Trust),
      <<"query_port">> => case QP of undefined -> null; _ -> QP end,
      <<"banned">> => case IdB64 of null -> false; _ -> (catch em_pop_store:is_banned(Id)) =:= true end,
      <<"verified">>  => is_binary(PK),
      <<"pubkey_fp">> => case PkB64 of undefined -> null; _ -> binary:part(PkB64, 0, min(12, byte_size(PkB64))) end,
      <<"root">>      => is_root_pubkey(PkB64),
      <<"role">>      => case Role of undefined -> null; _ -> atom_to_binary(Role, utf8) end,
      <<"last_seen">> => case LS of I when is_integer(I) -> I; _ -> null end}.

%% @private Public, topology-safe projection for the /filters directory.
filter_public_json(P) ->
    Trust = maps:get(trust, P, maps:get(<<"trust">>, P, 0.0)),
    Role  = maps:get(role, P, undefined),
    #{<<"name">>     => maps:get(name, P, maps:get(<<"name">>, P, <<>>)),
      <<"tier">>     => trust_tier(Trust),
      <<"role">>     => case Role of undefined -> null; _ when is_atom(Role) -> atom_to_binary(Role, utf8); _ -> Role end,
      <<"verified">> => is_binary(maps:get(pubkey, P, undefined))}.

%% @private Is this peer currently banned?
peer_banned(P) ->
    case maps:get(id, P, undefined) of
        Id when is_binary(Id) -> (catch em_pop_store:is_banned(Id)) =:= true;
        _ -> false
    end.

%% @private Coarse trust bucket used to colour the admin peer table.
trust_tier(T) when is_number(T), T < 0.10 -> <<"excluded">>;
trust_tier(T) when is_number(T), T < 0.40 -> <<"quarantine">>;
trust_tier(_) -> <<"normal">>.

%% @private Whether a base64 pubkey is one of the configured authoritative roots.
is_root_pubkey(undefined) -> false;
is_root_pubkey(PkB64) ->
    lists:member(PkB64, application:get_env(emquest, root_pubkeys, [])).

%% @private Gated POST action (ban/unban/trust). Body: {"id":"<base64 id>", ...}.
%% For `trust' also `"trust":Float'.
admin_action(Req0, Kind) ->
    case admin_auth(Req0) of
        {ok, Name} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            M = try json:decode(Body) catch _:_ -> #{} end,
            Tag = list_to_atom("admin_" ++ atom_to_list(Kind)),
            case maps:get(<<"id">>, M, undefined) of
                IdB64 when is_binary(IdB64) ->
                    Id = base64:decode(IdB64),
                    Res = do_admin(Kind, Id, M),
                    emquest_admin:audit(Name, atom_to_binary(Kind, utf8), IdB64),
                    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>},
                        iolist_to_binary(json:encode(#{<<"ok">> => true, <<"result">> => fmt_res(Res)})), Req1),
                        Tag};
                _ ->
                    {ok, cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>},
                        <<"{\"error\":\"missing id\"}">>, Req1), Tag}
            end;
        _ ->
            Tag = list_to_atom("admin_" ++ atom_to_list(Kind)),
            {ok, unauthorized(Req0), Tag}
    end.

%% @private Dispatch one admin peer action to `emquest_pop'.
do_admin(ban, Id, M)   -> emquest_pop:ban(Id, maps:get(<<"reason">>, M, <<"admin">>));
do_admin(unban, Id, _) -> emquest_pop:unban(Id);
do_admin(trust, Id, M) ->
    case maps:get(<<"trust">>, M, undefined) of
        T when is_number(T) -> emquest_pop:set_trust(Id, T * 1.0);
        _ -> {error, missing_trust}
    end.

%% @private Render an admin action result as a JSON-safe string.
fmt_res(ok) -> <<"ok">>;
fmt_res(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% @private 429 reply for a throttled route.
too_many(Req, Tag) ->
    {ok, cowboy_req:reply(429,
        #{<<"content-type">> => <<"application/json">>,
          <<"retry-after">>  => <<"10">>},
        <<"{\"error\":\"rate limited\"}">>, Req), Tag}.

%% @private 405 reply for a non-POST request on a POST-only route.
bad_method(Req, Tag) ->
    {ok, cowboy_req:reply(405,
        #{<<"content-type">> => <<"application/json">>},
        <<"{\"error\":\"Use POST\"}">>, Req), Tag}.

%% @doc Response headers for HTML pages: strict CSP + hardening. No inline
%% or third-party script is permitted (`script-src 'self''). `style-src'/
%% `font-src' carry an explicit allowance for fonts.googleapis.com/
%% fonts.gstatic.com because every template (index/drift/network) links
%% Google Fonts — without it the base policy would silently break font
%% loading on every HTML page. The search page uses the looser
%% {@link security_headers_app/1} instead (on-device SLM).
-spec security_headers(binary()) -> map().
security_headers(ContentType) ->
    #{<<"content-type">>            => ContentType,
      <<"content-security-policy">> =>
          <<"default-src 'self'; script-src 'self'; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src 'self' https://fonts.gstatic.com data:; "
            "img-src 'self' https: data:; media-src 'self' https:; "
            "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'">>,
      <<"x-content-type-options">>  => <<"nosniff">>,
      <<"x-frame-options">>         => <<"DENY">>,
      <<"referrer-policy">>         => <<"no-referrer">>}.

%% @doc CSP for the search app page (index.html) only. Same hardening as
%% security_headers/1 plus exactly what the on-device SLM needs
%% (priv/static/slm.js -> vendored priv/static/vendor/web-llm.js):
%%   * `'wasm-unsafe-eval'' in script-src   — WebLLM compiles WebAssembly.
%%   * huggingface.co + *.huggingface.co + *.hf.co in connect-src — model
%%     weights + mlc-chat-config.json are fetched from HF, and large weight
%%     shards now redirect to the HF Xet CDN (us.aws.cdn.hf.co, *.hf.co).
%%   * raw.githubusercontent.com in connect-src — the model wasm lib
%%     (mlc-ai/binary-mlc-llm-libs/.../web-llm-models/*.wasm) is fetched
%%     then instantiated in the browser.
%% The library itself is served same-origin, so script-src stays 'self';
%% no external <script> host is permitted. Every OTHER page keeps the
%% strict policy (connect-src 'self', no wasm-unsafe-eval).
-spec security_headers_app(binary()) -> map().
security_headers_app(ContentType) ->
    #{<<"content-type">>            => ContentType,
      <<"content-security-policy">> =>
          <<"default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src 'self' https://fonts.gstatic.com data:; "
            "img-src 'self' https: data:; media-src 'self' https:; "
            "connect-src 'self' https://huggingface.co https://*.huggingface.co "
            "https://*.hf.co https://raw.githubusercontent.com; "
            "frame-ancestors 'none'; base-uri 'self'; form-action 'self'">>,
      <<"x-content-type-options">>  => <<"nosniff">>,
      <<"x-frame-options">>         => <<"DENY">>,
      <<"referrer-policy">>         => <<"no-referrer">>}.

%% @private Self-contained health dashboard; fetches /health and renders.
status_page() ->
    <<"<!doctype html><html><head><meta charset=utf-8>"
      "<meta name=viewport content=\"width=device-width,initial-scale=1\">"
      "<title>Emergence status</title><style>"
      "body{font:14px system-ui,sans-serif;margin:0;background:#0f1115;color:#e6e6e6}"
      "header{padding:16px 20px;border-bottom:1px solid #232733;display:flex;gap:20px;align-items:baseline;flex-wrap:wrap}"
      "h1{font-size:16px;margin:0;color:#3ddc84}"
      ".k{color:#8b93a7}.v{color:#e6e6e6;font-weight:600}"
      "table{width:100%;border-collapse:collapse}"
      "th,td{text-align:left;padding:7px 20px;border-bottom:1px solid #1b1f29;white-space:nowrap}"
      "th{color:#8b93a7;font-weight:600;font-size:12px;position:sticky;top:0;background:#0f1115}"
      ".dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px}"
      ".up{background:#3ddc84}.down{background:#e5484d}"
      "td.num{text-align:right;font-variant-numeric:tabular-nums}"
      ".muted{color:#5b6274}</style></head><body>"
      "<header><h1>Emergence &middot; status</h1>"
      "<span class=k>peers <span class=v id=pc>-</span></span>"
      "<span class=k>alive <span class=v id=ac>-</span></span>"
      "<span class=k>cache L1/L2/miss <span class=v id=cache>-</span></span>"
      "<span class=k>redis <span class=v id=redis>-</span></span>"
      "<span class=muted id=ts></span></header>"
      "<table><thead><tr><th>filter</th><th>endpoint</th>"
      "<th class=num>latency</th><th class=num>fails</th></tr></thead>"
      "<tbody id=rows></tbody></table>"
      "<script src=\"/static/status.js\"></script>"
      "</body></html>">>.

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
    sse_reorder(Req, Sids, ScoresMap, true).

%% @private Reorder event; Final=false marks a progressive (mid-fetch) pass.
sse_reorder(Req, Sids, ScoresMap, Final) ->
    Payload = iolist_to_binary(json:encode(#{
        <<"type">>   => <<"reorder">>,
        <<"sids">>   => Sids,
        <<"scores">> => ScoresMap,
        <<"final">>  => Final
    })),
    cowboy_req:stream_body(<<"data: ", Payload/binary, "\n\n">>, nofin, Req).
