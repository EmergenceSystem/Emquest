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

    %% Step 2 — fan-out to disco in parallel.
    %% Read disco URL once here so each spawned process does not hit
    %% the config file independently.
    Parent = self(),
    Url    = disco_url(),
    Pids = [spawn(fun() ->
                Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
                case fetch_from_disco(Body, Url) of
                    {ok, #{<<"embryo_list">> := Items}} ->
                        Parent ! {disco_result, self(), Q, Items};
                    {error, R} ->
                        logger:warning("[emquest] disco fail ~s: ~p", [Q, R]),
                        Parent ! {disco_result, self(), Q, []}
                end
             end) || Q <- SubQueries],

    %% Collect results, streaming each item immediately as it arrives.
    %% collect_disco_streaming waits for the first response regardless
    %% of which PID sends it, so all agents run truly in parallel.
    %% Returns [{Sid, RawItem}] tagged with stream ids.
    TaggedItems = collect_disco_streaming(length(Pids), Req, [], 0),

    %% Step 3 — deduplicate by URL (first occurrence wins), keep sids
    DedupedTagged = deduplicate_tagged(TaggedItems),
    RawItems      = [Item || {_Sid, Item} <- DedupedTagged],

    sse(Req, status, iolist_to_binary([
        integer_to_binary(length(DedupedTagged)),
        " unique result(s). Ranking with LLM..."
    ])),

    %% Step 4 — rank; result is the same list reordered with scores
    Ranked = queen:rank(Query, RawItems),

    %% Rebuild {Sid, Score} in ranked order using an O(n) map lookup
    %% instead of a linear scan per item.
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
    %% JSON object keys must be binaries — convert integer sids.
    ScoresMap = maps:from_list([{integer_to_binary(S), Sc}
                                || {S, Sc} <- RankedSids, S =/= -1]),

    %% Only send reorder when the LLM returned a complete, valid ranking.
    %% A partial result means the LLM failed — keep items in arrival order
    %% and notify the client.
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

    %% Step 5 — synthesise a prose answer
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
%% it, so all sub-queries run truly in parallel.  Streams each
%% normalised item to the SSE client immediately upon receipt.
%%
%% Returns [{Sid :: integer(), RawItem :: map()}].
%% @end
%%--------------------------------------------------------------------
collect_disco_streaming(0, _Req, Acc, _Counter) ->
    lists:reverse(Acc);
collect_disco_streaming(Remaining, Req, Acc, Counter) ->
    receive
        {disco_result, _AnyPid, SubQ, Items} ->
            sse(Req, status, iolist_to_binary([
                "Got ", integer_to_binary(length(Items)),
                " result(s) for: \"", SubQ, "\""
            ])),
            {NewAcc, NewCounter} = lists:foldl(fun(Item, {A, Ctr}) ->
                NormItem = normalise_item(Item),
                sse_item(Req, Ctr, NormItem),
                {[{Ctr, Item} | A], Ctr + 1}
            end, {Acc, Counter}, Items),
            collect_disco_streaming(Remaining - 1, Req, NewAcc, NewCounter)
    after 8000 ->
        logger:warning("[emquest] disco timeout, ~p agent(s) did not respond", [Remaining]),
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

    Url   = first_defined(Props, [<<"url">>],                      null),
    Label = first_defined(Props, [<<"title">>, <<"label">>,
                                  <<"domain">>],                   <<"Result">>),
    Value = first_defined(Props, [<<"resume">>, <<"value">>,
                                  <<"description">>],              <<>>),
    Ips   = first_defined(Props, [<<"ips">>],                      null),

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
%% Disco HTTP
%%====================================================================

%% Url is resolved once in run_pipeline and passed down to avoid
%% reading the config file once per spawned sub-query process.
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
