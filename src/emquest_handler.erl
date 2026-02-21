%%%-------------------------------------------------------------------
%%% @doc HTTP handler for Cowboy routes.
%%%
%%% Each route passes an `action' atom as initial state:
%%%   `index'     — serves index.html
%%%   `query'     — forwards the query to em_disco on port 8080
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%%--------------------------------------------------------------------
%% Cowboy entry point — dispatches on the action set by the router.
%%--------------------------------------------------------------------

init(Req0, index) ->
    TemplatePath = filename:join([code:priv_dir(emquest), "templates", "index.html"]),
    {Code, Body, CT} = case file:read_file(TemplatePath) of
        {ok, Bin} ->
            {200, Bin, <<"text/html">>};
        {error, Reason} ->
            io:format("[emquest] Failed to read index.html: ~p~n", [Reason]),
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
            Req = json_reply(405, #{<<"error">> => <<"Use POST method for queries">>}, Req0),
            {ok, Req, query}
    end.

%%--------------------------------------------------------------------
%% Internal handlers
%%--------------------------------------------------------------------

handle_query(RawBody, Req) ->
    try json:decode(RawBody) of
        Map when is_map(Map) ->
            case maps:get(<<"query">>, Map, undefined) of
                undefined ->
                    json_reply(400, #{<<"error">> => <<"Missing 'query' key">>}, Req);
                Query when is_binary(Query) ->
                    forward_to_disco(Map, Req);
                _ ->
                    json_reply(400, #{<<"error">> => <<"Invalid 'query' value">>}, Req)
            end;
        _ ->
            json_reply(400, #{<<"error">> => <<"Expected a JSON object">>}, Req)
    catch
        _:_ ->
            json_reply(400, #{<<"error">> => <<"Invalid JSON">>}, Req)
    end.

forward_to_disco(Map, Req) ->
    ForwardUrl  = "http://localhost:8080/query",
    ForwardBody = iolist_to_binary(json:encode(Map)),
    io:format("[emquest] Forwarding query to ~s~n", [ForwardUrl]),
    case httpc:request(post,
                       {ForwardUrl, [], "application/json",
                        binary_to_list(ForwardBody)},
                       [], []) of
        {ok, {{_, 200, _}, _RespHeaders, ResponseBody}} ->
            RespBin = iolist_to_binary(ResponseBody),
            cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                RespBin, Req);
        {ok, {{_, Code, _}, _, ResponseBody}} ->
            io:format("[emquest] Disco returned ~p: ~p~n", [Code, ResponseBody]),
            cowboy_req:reply(Code,
                #{<<"content-type">> => <<"application/json">>},
                iolist_to_binary(ResponseBody), Req);
        {error, Reason} ->
            io:format("[emquest] Forwarding to disco failed: ~p~n", [Reason]),
            json_reply(500, #{<<"error">> => <<"Failed to forward request">>}, Req)
    end.

%%--------------------------------------------------------------------
%% Helper — encode a map as JSON and reply.
%%--------------------------------------------------------------------
json_reply(Code, Map, Req) ->
    cowboy_req:reply(Code,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(Map), Req).
