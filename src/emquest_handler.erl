%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_handler — HTTP Request Handler
%%%
%%% Handles two routes:
%%%   GET  /       → serves the index.html template
%%%   POST /query  → receives a query, fans it out through em_disco,
%%%                  synthesises results via `queen', and returns a
%%%                  structured JSON response to the browser.
%%%
%%% === Response format ===
%%%
%%% ```json
%%% {
%%%   "answer": "Human-readable synthesis",
%%%   "items":  [
%%%     { "label": "...", "value": "...", "url": "https://..." }
%%%   ]
%%% }
%%% '''
%%%
%%% `items' is optional and decided by the LLM in `queen'.
%%% `url' inside each item is optional.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(DISCO_URL, "http://localhost:8080/query").

%%--------------------------------------------------------------------
%% @doc Cowboy entry point — dispatches on the action set by the router.
%% @end
%%--------------------------------------------------------------------
init(Req0, index) ->
    TemplatePath = filename:join([code:priv_dir(emquest), "templates", "index.html"]),
    {Code, Body, CT} = case file:read_file(TemplatePath) of
        {ok, Bin} ->
            {200, Bin, <<"text/html">>};
        {error, Reason} ->
            logger:error("[emquest] Failed to read index.html: ~p", [Reason]),
            {500, <<"Internal Server Error">>, <<"text/plain">>}
    end,
    Req = cowboy_req:reply(Code, #{<<"content-type">> => CT}, Body, Req0),
    {ok, Req, index};

init(Req0, query) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, RawBody, Req1} = cowboy_req:read_body(Req0),
            Req = handle_query(RawBody, Req1),
            {ok, Req, query};
        _ ->
            Req = json_reply(405, #{<<"error">> => <<"Use POST">>}, Req0),
            {ok, Req, query}
    end.

%%====================================================================
%% Internal handlers
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Parses the request body, fetches results from em_disco,
%%      and synthesises them through the queen module.
%% @end
%%--------------------------------------------------------------------
handle_query(RawBody, Req) ->
    try json:decode(RawBody) of
        #{<<"query">> := Query} when is_binary(Query) ->
            %% Step 1 — expand the query into sub-queries
            SubQueries = queen:expand(Query, byte_size(Query) > 30),
            %% Step 2 — fan out to disco in parallel
            RawResults = fetch_all(SubQueries),
            %% Step 3 — synthesise + filter with LLM
            Synthesised = queen:process(Query, RawResults),
            json_reply(200, Synthesised, Req);
        _ ->
            json_reply(400, #{<<"error">> => <<"Missing 'query' key">>}, Req)
    catch
        _:_ -> json_reply(400, #{<<"error">> => <<"Invalid JSON">>}, Req)
    end.

%% Calls disco for each sub-query in parallel, aggregates and deduplicates.
-spec fetch_all([binary()]) -> list().
fetch_all(Queries) ->
    Parent = self(),
    %% Spawn one process per sub-query
    Pids = [spawn(fun() ->
                Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
                case fetch_from_disco(Body) of
                    {ok, #{<<"embryo_list">> := Items}} ->
                        Parent ! {result, self(), Items};
                    _ ->
                        Parent ! {result, self(), []}
                end
             end) || Q <- Queries],
    %% Collect all results
    All = collect(Pids, []),
    %% Deduplicate by url
    deduplicate(All).

-spec collect([pid()], list()) -> list().
collect([], Acc) -> Acc;
collect([Pid | Rest], Acc) ->
    receive
        {result, Pid, Items} -> collect(Rest, Acc ++ Items)
    after 8000 ->
        collect(Rest, Acc)
    end.

%% Removes duplicate embryos based on url property.
-spec deduplicate(list()) -> list().
deduplicate(Items) ->
    {Uniq, _} = lists:foldl(fun(Item, {Acc, Seen}) ->
        Url = maps:get(<<"url">>,
                maps:get(<<"properties">>, Item, #{}), <<>>),
        case sets:is_element(Url, Seen) orelse Url =:= <<>> of
            true  -> {Acc, Seen};
            false -> {[Item | Acc], sets:add_element(Url, Seen)}
        end
    end, {[], sets:new()}, Items),
    lists:reverse(Uniq).

%%--------------------------------------------------------------------
%% @private
%% @doc Forwards the raw request body to em_disco and parses the reply.
%% @end
%%--------------------------------------------------------------------
-spec fetch_from_disco(binary()) -> {ok, map()} | {error, term()}.
fetch_from_disco(Body) ->
    case httpc:request(post,
                       {?DISCO_URL, [], "application/json",
                        binary_to_list(Body)},
                       [{timeout, 10000}], []) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            try
                {ok, json:decode(iolist_to_binary(RespBody))}
            catch _:_ ->
                {error, invalid_disco_response}
            end;
        {ok, {{_, Code, _}, _, RespBody}} ->
            {error, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Encodes a map as JSON and replies with the given HTTP status.
%% @end
%%--------------------------------------------------------------------
-spec json_reply(non_neg_integer(), map(), cowboy_req:req()) ->
    cowboy_req:req().
json_reply(Code, Map, Req) ->
    cowboy_req:reply(Code,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Map), Req).
