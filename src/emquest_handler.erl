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
%%% 1. queen:expand/1      — split long queries into sub-queries (LLM),
%%%                          or `agent_planner' (`expand' meta-agent
%%%                          phase) when `[agents] planner' is on
%%% 2. queen:disco_nodes/0 — resolve all configured disco node URLs
%%% 3. Fan-out             — one process per (sub-query × disco node),
%%%                          all running in parallel
%%% 4. Collect             — stream each item to the SSE client as it
%%%                          arrives; 8 s per-process timeout
%%% 5. Deduplicate + rank  — first occurrence by URL wins, scored by
%%%                          `aggregate_and_rank/3'
%%% 6. Reorder             — re-scored by `agent_judge' (`rerank' phase)
%%%                          when `[agents] judge' is on, then always
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

-export([init/2, fetch_from_agent/2, fetch_preview/1, parse_stt_text/1, normalise_item/1,
         security_headers/1]).

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
    {ok, cowboy_req:reply(Code, security_headers(CT), Body, Req0), network};

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
    {ok, cowboy_req:reply(200, security_headers(<<"text/html; charset=utf-8">>),
        status_page(), Req0), status};

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
    end;
%% GET /media/prepare/:id — proxy velora's async prepare poll so the browser can
%% poll here (same origin) instead of us blocking the /media request open for the
%% whole warp. Returns {status:processing} | a done raster card | {status:error}.
init(Req0, media_prepare) ->
    Id = cowboy_req:binding(id, Req0),
    {Code, Body} = velora_prepare_poll(Id),
    {ok, cowboy_req:reply(Code, media_ct(), json:encode(Body), Req0), media_prepare};
init(Req0, stt) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case read_upload(Req0) of
                {ok, _Filename, Bytes, Req1} ->
                    case stt_forward(<<"audio.wav">>, Bytes) of
                        {ok, Text} ->
                            {ok, cowboy_req:reply(200, media_ct(),
                                json:encode(#{<<"text">> => Text}), Req1), stt};
                        {error, Reason} ->
                            {ok, cowboy_req:reply(502, media_ct(),
                                json:encode(#{<<"error">> => media_ebin(Reason)}), Req1), stt}
                    end;
                {error, Reason, Req1} ->
                    {ok, cowboy_req:reply(400, media_ct(),
                        json:encode(#{<<"error">> => media_ebin(Reason)}), Req1), stt}
            end;
        _ ->
            {ok, cowboy_req:reply(405, media_ct(),
                <<"{\"error\":\"Use POST\"}">>, Req0), stt}
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
                true  -> media_result(Req1, fetch_url_render(Url));
                false -> media_unsupported(Req1)
            end;
        _ -> media_err(Req1, 400, missing_url)
    end.

%% velora's warp is asynchronous: answer the browser right away with a poll URL
%% (served here at /media/prepare/:id) instead of blocking this request for the
%% whole render. A legacy synchronous velora still yields a ready card.
media_result(Req, {ok, {processing, PrepId}}) ->
    Body = #{<<"status">> => <<"processing">>,
             <<"prepare">> => PrepId,
             <<"poll">> => <<"/media/prepare/", PrepId/binary>>},
    {ok, cowboy_req:reply(202, media_ct(), json:encode(Body), Req), media};
media_result(Req, {ok, {ready, Card}}) ->
    {ok, cowboy_req:reply(200, media_ct(), json:encode(Card), Req), media};
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

stt_base() -> application:get_env(emquest, stt_url, "http://127.0.0.1:8086").

stt_forward(Filename, Bytes) ->
    {Boundary, MBody} = build_stt_multipart(Filename, Bytes),
    CT = "multipart/form-data; boundary=" ++ Boundary,
    case httpc:request(post,
                       {stt_base() ++ "/inference", [], CT, MBody},
                       [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Hdrs, Body}} -> {ok, parse_stt_text(Body)};
        {ok, {{_, Code, _}, _, _}}        -> {error, iolist_to_binary(io_lib:format("stt ~w", [Code]))};
        {error, R}                        -> {error, R}
    end.

%% whisper.cpp /inference returns {"text": "..."}.
parse_stt_text(Body) ->
    case (try json:decode(Body) catch _:_ -> #{} end) of
        #{<<"text">> := T} when is_binary(T) -> string:trim(T);
        _ -> <<>>
    end.

build_stt_multipart(Filename, Bytes) ->
    Boundary = "emqstt" ++ integer_to_list(erlang:unique_integer([positive])),
    Body = iolist_to_binary([
        "--", Boundary, "\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"", Filename, "\"\r\n",
        "Content-Type: audio/wav\r\n\r\n",
        Bytes, "\r\n",
        "--", Boundary, "--\r\n"]),
    {Boundary, Body}.

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

velora_base() -> application:get_env(emquest, velora_url, "http://localhost:8081").
tiles_base()  -> list_to_binary(application:get_env(emquest, velora_tiles_base, "https://velora.roques.me")).

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

%% Kick off velora's async warp. /render answers 202 {status:processing, prepare}
%% instantly (the warp is backgrounded), so this returns the prepare id for the
%% browser to poll — it does NOT block on the render. A legacy synchronous velora
%% (a ready {id,...}) still yields a ready card.
velora_render(Uri) ->
    RBody = iolist_to_binary(json:encode(#{<<"uri">> => Uri})),
    case httpc:request(post, {velora_base() ++ "/render",
                              [{"content-type", "application/json"}],
                              "application/json", RBody},
                       [{timeout, 15000}], [{body_format, binary}]) of
        {ok, {{_, S, _}, _, Resp}} when S =:= 200; S =:= 202 ->
            case json:decode(Resp) of
                #{<<"status">> := <<"processing">>, <<"prepare">> := P} ->
                    {ok, {processing, P}};
                #{<<"id">> := _} = M -> {ok, {ready, render_card(M)}}
            end;
        {ok, {{_, C, _}, _, _}} -> {error, {render_http, C}};
        {error, R} -> {error, R}
    end.

%% One poll of velora's async prepare, proxied for /media/prepare/:id. Maps
%% velora's /prepare/:id answer to {HttpCode, JsonBody} for the browser.
velora_prepare_poll(Id) ->
    Url = velora_base() ++ "/prepare/" ++ binary_to_list(Id),
    case httpc:request(get, {Url, []}, [{timeout, 15000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, B}} ->
            case (try json:decode(B) catch _:_ -> #{} end) of
                #{<<"status">> := <<"done">>} = D ->
                    {200, (render_card(D))#{<<"status">> => <<"done">>}};
                #{<<"status">> := <<"error">>} = E ->
                    {200, #{<<"status">> => <<"error">>,
                            <<"error">> => media_ebin(maps:get(<<"error">>, E, <<"error">>))}};
                _ ->
                    {200, #{<<"status">> => <<"processing">>}}
            end;
        {ok, {{_, 404, _}, _, _}} -> {404, #{<<"status">> => <<"not_found">>}};
        {ok, {{_, C, _}, _, _}}   -> {502, #{<<"error">> => media_ebin({prepare_http, C})}};
        {error, R}                -> {502, #{<<"error">> => media_ebin(R)}}
    end.

render_card(M) ->
    Id = maps:get(<<"id">>, M),
    NZ = maps:get(<<"maxNativeZoom">>, M, 19),
    #{<<"type">> => <<"raster">>, <<"id">> => Id,
      <<"bounds">> => maps:get(<<"bounds">>, M, null),
      <<"maxNativeZoom">> => NZ,
      <<"tiles">> => <<(tiles_base())/binary, "/tiles/", Id/binary, "/{z}/{x}/{y}">>}.

%% URL path: Emquest fetches the image itself (a normal GET works with hosts that
%% reject GDAL's /vsicurl Range requests, e.g. Wikimedia), then uploads the bytes
%% to velora — the same path as a file upload. Avoids /vsicurl entirely.
fetch_url_render(Url) ->
    case fetch_image(Url) of
        {ok, Bytes} -> velora_upload_render(url_filename(Url), Bytes);
        {error, R}  -> {error, R}
    end.

fetch_image(Url) ->
    _ = application:ensure_all_started(ssl),
    emquest_safeurl:safe_get(Url,
        [{"User-Agent", "velora/1.0"}, {"accept", "image/*"}],
        [{timeout, 30000}]).

url_filename(Url) ->
    Path = case binary:split(Url, <<"?">>) of [P | _] -> P; _ -> Url end,
    case binary:split(Path, <<"/">>, [global, trim_all]) of
        [] -> <<"image">>;
        Ps -> lists:last(Ps)
    end.

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

    %% Step 1 — expand query into sub-queries.
    %%
    %% Goes through the meta-agent registry's `expand' phase first
    %% (`agent_planner', LLM-driven decomposition via ollama). When the
    %% Planner is off, ollama is down/slow, or its output doesn't parse,
    %% it returns `skip' and `CtxExpand' below has no `subqueries' key
    %% — we fall back to the exact pre-meta-agent behaviour:
    %% `queen:expand/1' (HF topics -> local_keywords).
    sse(Req, status, <<"Expanding query...">>),
    CtxExpand = em_agent:run_phase(expand, #{query => Query}),
    SubQueries = case CtxExpand of
        #{subqueries := PlannedSubQueries}
          when is_list(PlannedSubQueries), PlannedSubQueries =/= [] ->
            PlannedSubQueries;
        _ ->
            queen:expand(Query)
    end,

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

    %% Step 6 — LLM re-rank of the top-N via the meta-agent registry's
    %% `rerank' phase (`agent_judge'). `TaggedItems' has one entry per
    %% streamed sid (`Sid' is the running counter assigned in
    %% `collect_disco_streaming/4', globally unique), so it doubles as
    %% the sid -> raw item lookup the Judge needs for title/url/resume.
    %% When the Judge is off, ollama is down/slow, or its output doesn't
    %% parse, `run_phase/2' returns `skip' and `CtxRerank' below has no
    %% `sortedsids' key — we fall back to the exact pre-meta-agent
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
mmr_on() ->
    case maps:get("mmr", emquest_rank:conf(), "on") of
        "off" -> false;
        _     -> true
    end.

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
progressive_on() ->
    case maps:get("progressive", emquest_rank:conf(), "on") of
        "off" -> false;
        _     -> true
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
    Base0 = #{<<"label">> => html_escape(cap(Label, 256)),
              <<"value">> => html_escape(cap(Value, 2048)),
              <<"score">> => Score, <<"type">>  => Type},
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
%% filtered (http/https only); text fields are HTML-escaped and length-capped.
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
                      V when is_binary(V) -> Acc#{K => html_escape(cap(V, 256))};
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

%% @private HTML-escape a binary so peer text cannot inject markup when rendered.
html_escape(B) when is_binary(B) ->
    << (esc_char(C)) || <<C>> <= B >>;
html_escape(X) -> X.

esc_char($&) -> <<"&amp;">>;
esc_char($<) -> <<"&lt;">>;
esc_char($>) -> <<"&gt;">>;
esc_char($") -> <<"&quot;">>;
esc_char($') -> <<"&#39;">>;
esc_char(C)  -> <<C>>.

%% @private Return the URL only if scheme is http/https, else null.
safe_url(null) -> null;
safe_url(U) when is_binary(U) ->
    case emquest_safeurl:check_scheme(U) of
        ok -> U;
        _  -> null
    end;
safe_url(_) -> null.

%% @private Truncate an over-long binary field.
cap(B, Max) when is_binary(B), byte_size(B) > Max ->
    binary:part(B, 0, Max);
cap(B, _) -> B.

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
    case httpc:request(post,
                       {Url, em_auth_headers(), "application/json",
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
%% @private
%% @doc Append the media-bank filters (images/audio/video) to the hash-selected
%% peer set, so a plain query like "f40" also reaches them. Deduplicated by
%% endpoint; media filters already selected are not added twice.
ensure_media_peers(Selected) ->
    Always = [<<"openverse_filter">>, <<"wikimedia_commons_filter">>,
              <<"nasa_images_filter">>,
              <<"sepiasearch_filter">>,
              <<"cleveland_filter">>, <<"gbif_filter">>, <<"met_filter">>],
    SelKeys = [endpoint_key(P) || {P, _} <- Selected],
    All = try emquest_pop:all_peers() catch _:_ -> [] end,
    Extra = [{P, 1.0}
             || P <- All,
                lists:member(maps:get(name, P, <<>>), Always),
                maps:get(query_port, P, undefined) =/= undefined,
                not lists:member(endpoint_key(P), SelKeys)],
    Selected ++ Extra.

endpoint_key(P) ->
    {maps:get(host, P, undefined), maps:get(query_port, P, undefined)}.

-spec spawn_pop_workers([binary()], [{map(), float()}], pid()) -> [pid()].
spawn_pop_workers(SubQueries, Peers, Parent) ->
    [spawn(fun() ->
        H     = binary_to_list(maps:get(host, PeerMap)),
        QP    = maps:get(query_port, PeerMap),
        Trust = maps:get(trust, PeerMap, ?TRUST_INIT),
        BP    = binary_to_list(maps:get(base_path, PeerMap, <<>>)),
        Url   = lists:flatten(
                    agent_query_url(H, QP, BP)),
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
%% (item_vec_score/dot_product moved into emquest_rank as hash_vec/dot_prod)

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
    case emquest_safeurl:safe_get(Url,
             [{"User-Agent", "Mozilla/5.0 (compatible; Emquest/1.0)"}],
             [{timeout, 5000}]) of
        {ok, Body} -> {ok, best_description(Body)};
        {error, R} -> {error, R}
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
%% @private
nn(undefined) -> null;
nn(V)         -> V.

%% @doc Response headers for HTML pages: strict CSP + hardening.
%% `img-src` allows self + https (peer thumbnails are proxied/https only);
%% no inline or third-party script is permitted. `style-src'/`font-src' carry
%% an explicit allowance for fonts.googleapis.com/fonts.gstatic.com because
%% every template (index/drift/network) links Google Fonts — without it the
%% given base policy would silently break font loading on every HTML page.
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
