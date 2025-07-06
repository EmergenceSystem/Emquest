-module(emquest_handler).
-export([init/2, handle_query/1, handle_summarize/1]).
-include_lib("embryo/src/embryo.hrl").

init(Req, [index]) ->
    {ok, IndexData} = file:read_file(code:priv_dir(emquest) ++ "/templates/index.html"),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/html">>},
        IndexData,
        Req
    ),
    {ok, Req2, []};

init(Req, [query]) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            handle_query(Req);
        _ ->
            Req2 = cowboy_req:reply(405, Req),
            {ok, Req2, []}
    end;

init(Req, [summarize]) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            handle_summarize(Req);
        _ ->
            Req2 = cowboy_req:reply(405, Req),
            {ok, Req2, []}
    end.

handle_query(Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    io:format("Request body received: ~s~n", [Body]),
    JsonData = jsx:decode(Body, [return_maps]),
    case maps:get(<<"query">>, JsonData, undefined) of
        undefined ->
            io:format("Missing 'query' parameter in the request~n"),
            {error, 400, Req2, []};
        Query when is_binary(Query), byte_size(Query) > 0 ->
            io:format("Received query: ~s~n", [Query]),
            ServerUrl = embryo:get_em_disco_url(),
            io:format("Sending query to em_disco at: ~p~n", [ServerUrl]),
            ServerUrlBin = case is_binary(ServerUrl) of
                true -> ServerUrl;
                false -> list_to_binary(ServerUrl)
            end,
            Url = <<ServerUrlBin/binary, "/query">>,
            Headers = [{<<"content-type">>, <<"application/json">>}],
            case hackney:post(Url, Headers, Query, []) of
                {ok, StatusCode, RespHeaders, ClientRef} ->
                    case hackney:body(ClientRef) of
                        {ok, RespBody} ->
                            io:format("Received response with status ~p~n", [StatusCode]),
                            Result = {ok, StatusCode, RespHeaders, RespBody, Req2},
                            handle_result(Result);
                        _ ->
                            io:format("Failed to read response body~n"),
                            Result = {error, 500, Req2, []},
                            handle_result(Result)
                    end;
                _Error ->
                    io:format("Error in HTTP request to em_disco~n"),
                    Result = {error, 500, Req2, []},
                    handle_result(Result)
            end;
        _ ->
            io:format("Invalid query format~n"),
            Result = {error, 400, Req2, []},
            handle_result(Result)
    end.

handle_result({ok, StatusCode, RespHeaders, ResponseBody, Req3}) ->
    FinalReq = cowboy_req:reply(StatusCode, maps:from_list(RespHeaders), ResponseBody, Req3),
    {ok, FinalReq, []};
handle_result({ok, StatusCode, Req3, ResponseBody}) ->
    FinalReq = cowboy_req:reply(StatusCode, #{}, ResponseBody, Req3),
    {ok, FinalReq, []};
handle_result({error, StatusCode, Req3, _}) ->
    io:format("Error response with status ~p~n", [StatusCode]),
    FinalReq = cowboy_req:reply(StatusCode, Req3),
    {ok, FinalReq, []}.

handle_summarize(Req) ->
    try
        handle_summarize_internal(Req)
    catch
        Class:Reason:Stacktrace ->
            io:format("Fatal error in handle_summarize: ~p:~p~n~p~n", [Class, Reason, Stacktrace]),
            EmergencyResponse = jsx:encode(#{<<"summary">> => <<"Erreur lors du traitement de la demande">>}),
            cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, EmergencyResponse, Req)
    end.

handle_summarize_internal(Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    
    Content = try
        case Body of
            <<>> -> 
                "Contenu vide";
            _ -> 
                try
                    JsonData = jsx:decode(Body, [return_maps]),
                    case maps:get(<<"html">>, JsonData, undefined) of
                        undefined -> binary_to_list(Body);
                        HtmlContent -> binary_to_list(HtmlContent)
                    end
                catch
                    _:_ -> binary_to_list(Body)
                end
        end
    catch
        _:_ -> "Parsing error"
    end,
    
    FrenchPrompt = "Summarize the following content in French. For each important point, cite the sources/links provided in the text using the format (Source: URL). Be precise in French. Here is the content to summarize: " ++ Content,
    
    try
        Result = ollama_summarizer:summarize_html(FrenchPrompt),
        io:format("Summarizer result: ~p~n", [Result]),
        
        case Result of
            {ok, Summary} ->
                SummaryBinary = try
                    case Summary of
                        Bin when is_binary(Bin) -> Bin;
                        List when is_list(List) -> list_to_binary(List);
                        Other -> list_to_binary(io_lib:format("~p", [Other]))
                    end
                catch
                    _:_ -> <<"Error in summarize">>
                end,
                
                SuccessJson = jsx:encode(#{<<"summary">> => SummaryBinary}),
                cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, SuccessJson, Req2);
                
            {error, Reason} ->
                io:format("Summarizer error: ~p~n", [Reason]),
                ErrorJson = jsx:encode(#{<<"summary">> => <<"Erreur de summarization">>}),
                cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, ErrorJson, Req2);
                
            Other ->
                io:format("Unexpected summarizer result: ~p~n", [Other]),
                UnexpectedJson = jsx:encode(#{<<"summary">> => <<"Résultat inattendu du summarizer">>}),
                cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, UnexpectedJson, Req2)
        end
    catch
        SumClass:SumReason:SumStacktrace ->
            io:format("Exception in summarizer: ~p:~p~n~p~n", [SumClass, SumReason, SumStacktrace]),
            ExceptionJson = jsx:encode(#{<<"summary">> => <<"Exception lors de la summarization">>}),
            cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, ExceptionJson, Req2)
    end.
