-module(mock_relay_hub_handler).
-behaviour(cowboy_handler).
-export([init/2]).

%% @doc Stub for `POST /relay/query'. Ignores the request body (the
%% real em_disco_relay handler parses `{peer_id, query}' and forwards
%% to the target filter's WS connection — irrelevant here) and always
%% answers with the fixed, pre-signed response given at mount time, the
%% same shape em_disco_ws/em_disco_relay round-trip from a real filter's
%% signed `result' frame: `{"results": [...], "signer_id": .., "signature": ..}'.
init(Req0, #{resp := RespMap} = State) ->
    Body = iolist_to_binary(json:encode(RespMap)),
    Req  = cowboy_req:reply(200,
               #{<<"content-type">> => <<"application/json">>},
               Body, Req0),
    {ok, Req, State}.
