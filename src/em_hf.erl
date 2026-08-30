%%%-------------------------------------------------------------------
%%% @doc em_hf — HTTP client for the hf_topics embedding microservice.
%%%
%%% Mirrors `queen:hf_topics/1''s httpc pattern. Talks to hf_topics'
%%% `POST /embed' endpoint (127.0.0.1:8085) to turn text into
%%% multilingual MiniLM sentence embeddings, used by `em_librarian'
%%% (filter capability index) and `agent_router' (semantic query
%%% routing).
%%%
%%% Every function returns `error' (not an exception) on any failure
%%% — service down, timeout, malformed response — so callers can fall
%%% back to today's behaviour without a try/catch of their own.
%%% @end
%%%-------------------------------------------------------------------
-module(em_hf).

-export([embed/1, embed_many/1]).

-define(EMBED_URL, "http://127.0.0.1:8085/embed").
-define(TIMEOUT, 4000).

%%--------------------------------------------------------------------
%% @doc Embed a single piece of text.
%%
%% Returns `error' on any failure (service down, timeout, bad
%% response).
%% @end
%%--------------------------------------------------------------------
-spec embed(binary()) -> {ok, [float()]} | error.
embed(Text) when is_binary(Text) ->
    case embed_many([Text]) of
        {ok, [Vec]} -> {ok, Vec};
        _           -> error
    end.

%%--------------------------------------------------------------------
%% @doc Embed a batch of texts in a single request.
%%
%% Returns `{ok, Vecs}' with `Vecs' in the same order as `Texts', or
%% `error' on any failure.
%% @end
%%--------------------------------------------------------------------
-spec embed_many([binary()]) -> {ok, [[float()]]} | error.
embed_many([]) ->
    {ok, []};
embed_many(Texts) when is_list(Texts) ->
    _ = application:ensure_all_started(inets),
    Body = iolist_to_binary(json:encode(#{<<"texts">> => Texts})),
    Req  = {?EMBED_URL, [], "application/json", Body},
    case httpc:request(post, Req, [{timeout, ?TIMEOUT}],
                        [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBin}} ->
            case catch json:decode(RespBin) of
                #{<<"embeddings">> := Embs} when is_list(Embs) ->
                    case length(Embs) =:= length(Texts)
                         andalso lists:all(fun is_num_list/1, Embs) of
                        true  -> {ok, [[float(F) || F <- Vec] || Vec <- Embs]};
                        false -> error
                    end;
                _ -> error
            end;
        _ -> error
    end.

%%====================================================================
%% Internal
%%====================================================================

%% @private
is_num_list(L) when is_list(L) -> lists:all(fun is_number/1, L);
is_num_list(_) -> false.
