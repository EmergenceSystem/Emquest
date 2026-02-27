%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_handler — Streaming HTTP Handler (Server-Sent Events)
%%%
%%% GET  /       → serves index.html
%%% POST /query  → SSE stream of progress events + final results
%%%
%%% === SSE event types ===
%%%
%%%   {"type": "status",  "message": "..."}
%%%   {"type": "item",    "item": {...}, "sid": N}  ← streamed immediately
%%%   {"type": "reorder", "sids": [N,...], "scores": {N: 0-3,...}}
%%%   {"type": "answer",  "message": "..."}         ← LLM synthesis
%%%   {"type": "error",   "message": "..."}
%%%
%%% Items are streamed one-by-one as each agent responds, then
%%% re-ordered and scored once ranking is complete.
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
    sse(Req, status, iolist_to_binary([
        "Querying agents with ",
        integer_to_binary(length(SubQueries)), " sub-query(ies)..."
    ])),

    %% Step 2 — fan-out to disco in parallel
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

    %% Collect results, streaming each item immediately as it arrives
    %% Returns list of {Sid, RawItem} tagged with stream ids
    TaggedItems = collect_disco_streaming(Pids, Req, [], 0),

    %% Step 3 — deduplicate by URL (first occurrence wins), keep sids
    DedupedTagged = deduplicate_tagged(TaggedItems),
    RawItems      = [Item || {_Sid, Item} <- DedupedTagged],

    sse(Req, status, iolist_to_binary([
        integer_to_binary(length(DedupedTagged)),
        " unique result(s). Ranking with LLM..."
    ])),

    %% Step 4 — rank; result is the same list reordered with scores
    Ranked = queen:rank(Query, RawItems),

    %% Rebuild {Sid, ScoredItem} in ranked order
    %% Match by original position in DedupedTagged
    SidArr = list_to_tuple([Sid || {Sid, _} <- DedupedTagged]),
    RankedSids = lists:map(fun(ScoredItem) ->
        %% Find which position this item occupies in DedupedTagged
        %% queen:rank preserves items; match by identity (same map ref)
        Idx = find_item_index(ScoredItem, RawItems, 0),
        Sid = case Idx >= 0 andalso Idx < tuple_size(SidArr) of
            true  -> element(Idx + 1, SidArr);
            false -> -1
        end,
        Score = maps:get(<<"score">>, ScoredItem, 0),
        {Sid, Score}
    end, Ranked),

    ValidSids   = [S || {S, _} <- RankedSids, S =/= -1],
    %% JSON object keys must be binaries — convert integer sids to binary strings.
    ScoresMap   = maps:from_list([{integer_to_binary(S), Sc}
                                  || {S, Sc} <- RankedSids, S =/= -1]),

    %% Only send reorder if ranking produced a full valid result.
    %% An empty or partial ValidSids means the LLM failed — keep items as-is.
    AllSids = [S || {S, _} <- DedupedTagged],
    case length(ValidSids) > 0 andalso
         lists:sort(ValidSids) =:= lists:sort(AllSids) of
        true  -> sse_reorder(Req, ValidSids, ScoresMap);
        false ->
            io:format("[emquest] Skipping reorder: ranked ~p / ~p items~n",
                      [length(ValidSids), length(AllSids)])
    end,

    %% Step 5 — synthesise prose answer
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
%% @doc Collects agent results, streaming each normalised item immediately.
%%
%% Returns `[{Sid :: integer(), RawItem :: map()}]' so the caller can
%% match the stream ids back to their original items after ranking.
%% @end
%%--------------------------------------------------------------------
collect_disco_streaming([], _Req, Acc, _Counter) ->
    lists:reverse(Acc);
collect_disco_streaming([Pid | Rest], Req, Acc, Counter) ->
    receive
        {disco_result, Pid, SubQ, Items} ->
            sse(Req, status, iolist_to_binary([
                "Got ", integer_to_binary(length(Items)),
                " result(s) for: \"", SubQ, "\""
            ])),
            {NewAcc, NewCounter} = lists:foldl(fun(Item, {A, Ctr}) ->
                NormItem = normalise_item(Item),
                sse_item(Req, Ctr, NormItem),
                {[{Ctr, Item} | A], Ctr + 1}
            end, {Acc, Counter}, Items),
            collect_disco_streaming(Rest, Req, NewAcc, NewCounter)
    after 8000 ->
        logger:warning("[emquest] disco timeout pid ~p", [Pid]),
        collect_disco_streaming(Rest, Req, Acc, Counter)
    end.

%%====================================================================
%% Deduplication (tagged)
%%====================================================================

deduplicate_tagged(TaggedItems) ->
    {Uniq, _} = lists:foldl(fun({Sid, Item}, {Acc, Seen}) ->
        Props = maps:get(<<"properties">>, Item, #{}),
        Url   = maps:get(<<"url">>, Props, <<>>),
        case Url of
            %% No URL (DNS, generic…) — always keep, nothing to deduplicate on.
            <<>> ->
                {[{Sid, Item} | Acc], Seen};
            %% Has a URL — deduplicate by it.
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
    Type  = maps:get(<<"type">>, Item, <<"generic">>),

    Url   = first_defined(Props, [<<"url">>],                       null),
    Label = first_defined(Props, [<<"title">>, <<"label">>,
                                   <<"domain">>],                   <<"Result">>),
    Value = first_defined(Props, [<<"resume">>, <<"value">>,
                                   <<"description">>],              <<>>),
    Ips   = first_defined(Props, [<<"ips">>],                       null),

    Base = #{<<"label">> => Label, <<"value">> => Value,
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
%% Helpers
%%====================================================================

%% Find the 0-based index of Item in List by map equality (ignoring score).
find_item_index(_Item, [], _Idx)      -> -1;
find_item_index(Item, [H | T], Idx)  ->
    %% Compare without the injected score field
    A = maps:remove(<<"score">>, Item),
    B = maps:remove(<<"score">>, H),
    case A =:= B of
        true  -> Idx;
        false -> find_item_index(Item, T, Idx + 1)
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
