%%%-------------------------------------------------------------------
%%% @doc HTTP handler for Wade routes.
%%%-------------------------------------------------------------------
-module(emquest_handler).
-export([
    handle_index/1,
    handle_query/1,
    handle_summarize/1,
    serve_static/1
]).

%% Include Wade's header to get the req record definition
-include_lib("wade/include/wade.hrl").

%% @doc Serve the index.html template for the root route.
handle_index(_Req) ->
    TemplatePath = filename:join([code:priv_dir(emquest), "templates", "index.html"]),
    case file:read_file(TemplatePath) of
        {ok, BinContent} ->
            {200, BinContent, [{"content-type", "text/html"}]};
        {error, Reason} ->
            io:format("Failed to read index.html: ~p~n", [Reason]),
            {500, <<"Internal Server Error">>, [{"content-type", "text/plain"}]}
    end.

%% @doc Handle GET/POST /query requests and forward to port 8080.
handle_query(Req) ->
    Method = wade:method(Req),
    
    case Method of
        post ->
            ParsedBody = Req#req.body,
            
            case ParsedBody of
                JsonData when is_map(JsonData) ->
                    Query = maps:get(<<"query">>, JsonData, undefined),
                    case Query of
                        undefined ->
                            ErrBody = jsx:encode(#{<<"error">> => <<"Missing 'query' key">>}),
                            {400, ErrBody, [{"content-type", "application/json"}]};
                        _ when is_binary(Query) ->
                            ForwardBody = jsx:encode(JsonData),
                            
                            ForwardUrl = "http://localhost:8080/query",
                            Headers = [{"content-type", "application/json"}],
                            io:format("Forwarding query to ~p~n", [ForwardUrl]),
                            
                            case wade:request(post, ForwardUrl, Headers, ForwardBody) of
                                {ok, _StatusCode, _RespHeaders, ResponseBody} ->
                                    io:format("Received response from disco~n"),
                                    {200, ResponseBody, [{"content-type", "application/json"}]};
                                {error, Reason} ->
                                    io:format("Forwarding to disco failed: ~p~n", [Reason]),
                                    ErrBody = jsx:encode(#{<<"error">> => <<"Failed to forward request">>}),
                                    {500, ErrBody, [{"content-type", "application/json"}]}
                            end;
                        _ ->
                            ErrBody = jsx:encode(#{<<"error">> => <<"Invalid 'query' value">>}),
                            {400, ErrBody, [{"content-type", "application/json"}]}
                    end;
                [] ->
                    io:format("Empty or invalid body~n"),
                    ErrBody = jsx:encode(#{<<"error">> => <<"Empty or invalid JSON body">>}),
                    {400, ErrBody, [{"content-type", "application/json"}]};
                _ ->
                    io:format("Unexpected body format: ~p~n", [ParsedBody]),
                    ErrBody = jsx:encode(#{<<"error">> => <<"Invalid JSON body format">>}),
                    {400, ErrBody, [{"content-type", "application/json"}]}
            end;
        get ->
            io:format("GET request received~n"),
            ErrBody = jsx:encode(#{<<"error">> => <<"Use POST method for queries">>}),
            {405, ErrBody, [{"content-type", "application/json"}]};
        _ ->
            io:format("Method ~p not allowed~n", [Method]),
            {405, <<"Method Not Allowed">>, [{"content-type", "text/plain"}]}
    end.

%% @doc Handle POST /summarize requests.
handle_summarize(Req) ->
    Method = wade:method(Req),
    case Method of
        post ->
            ParsedBody = Req#req.body,
            case ParsedBody of
                JsonData when is_map(JsonData) ->
                    Content = maps:get(<<"html">>, JsonData, <<>>),
                    _Prompt = "Summarize in French: " ++ binary_to_list(Content),
                    Summary = "Summary: " ++ binary_to_list(Content),
                    ResponseJson = jsx:encode(#{<<"summary">> => list_to_binary(Summary)}),
                    {200, ResponseJson, [{"content-type", "application/json"}]};
                _ ->
                    ErrJson = jsx:encode(#{<<"error">> => <<"Invalid JSON">>}),
                    {400, ErrJson, [{"content-type", "application/json"}]}
            end;
        _ ->
            {405, <<"Method Not Allowed">>, [{"content-type", "text/plain"}]}
    end.

%% @doc Serve static files from priv/static/.
serve_static(Req) ->
    FilePath = wade:param(Req, path),
    StaticDir = filename:join([code:priv_dir(emquest), "static"]),
    FullPath = filename:join([StaticDir, FilePath]),
    case filelib:is_regular(FullPath) of
        true ->
            case file:read_file(FullPath) of
                {ok, BinContent} ->
                    MimeType = case filename:extension(FilePath) of
                        ".css" -> "text/css";
                        ".js" -> "application/javascript";
                        ".html" -> "text/html";
                        _ -> "application/octet-stream"
                    end,
                    {200, BinContent, [{"content-type", MimeType}]};
                {error, Reason} ->
                    io:format("Failed to read file ~p: ~p~n", [FullPath, Reason]),
                    {500, <<"Internal Server Error">>, []}
            end;
        false ->
            io:format("File not found: ~p~n", [FullPath]),
            {404, <<"File Not Found">>, []}
    end.
