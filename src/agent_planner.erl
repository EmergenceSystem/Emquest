%%%-------------------------------------------------------------------
%%% @doc agent_planner — query decomposition (the `expand' phase
%%% meta-agent).
%%%
%%% Upgrades `queen:expand/1' with an LLM-driven decomposition: the
%%% raw query is sent to ollama (via `queen''s existing LLM plumbing)
%%% with a strict prompt asking for 1–5 focused sub-queries, returned
%%% as a JSON array of strings. The original query is always kept as
%%% the first sub-query, exactly like `queen:expand/1' does today.
%%%
%%% === Guardrails (never worse than today) ===
%%%
%%% <ul>
%%%   <li>ollama timeout / down / any error from `call_handler_timeout/4'
%%%       => `skip'.</li>
%%%   <li>Non-JSON, non-array, or all-empty-string output => `skip'.</li>
%%% </ul>
%%%
%%% On `skip', `em_agent:run_phase/2' leaves `Ctx' unchanged, and
%%% `emquest_handler' falls back to `queen:expand/1' — today's exact
%%% behaviour.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_planner).
-behaviour(em_agent).
-include_lib("kernel/include/logger.hrl").

-export([run/1]).
-export([parse_subqueries/2]).

-define(MAX_SUBQUERIES, 5).

%%--------------------------------------------------------------------
%% @doc `em_agent' callback. `Ctx' must contain a `query' binary.
%% @end
%%--------------------------------------------------------------------
-spec run(map()) -> {ok, map()} | skip.
run(#{query := Query} = Ctx) when is_binary(Query) ->
    Conf        = queen:read_llm_conf(),
    Provider    = maps:get(provider, Conf, <<"mistral">>),
    Prompt      = build_prompt(Query),
    HandlerConf = queen:handler_conf(Provider, Conf,
        <<"You decompose search queries. Reply only with a JSON array "
          "of strings.">>),
    Timeout = queen:llm_timeout(Conf),
    case queen:call_handler_timeout(Provider, Prompt, HandlerConf, Timeout) of
        {ok, Text} ->
            case parse_subqueries(Text, Query) of
                []   -> skip;
                List -> {ok, Ctx#{subqueries => List}}
            end;
        {error, Reason} ->
            ?LOG_INFO("[agent_planner] ollama call failed: ~p", [Reason]),
            skip
    end;
run(_Ctx) ->
    skip.

%%--------------------------------------------------------------------
%% @doc Parse the raw LLM response text into a bounded, deduplicated
%% sub-query list with `Query' always first — mirrors the shape
%% `queen:expand/1' returns. Pure — no I/O — so eunit can exercise it
%% directly against well-formed and malformed fixtures.
%%
%% Returns `[]' when the response is not a JSON array of strings, or
%% contains no usable (non-empty) strings — the caller treats `[]' as
%% "fall back to `queen:expand/1'".
%% @end
%%--------------------------------------------------------------------
-spec parse_subqueries(binary(), binary()) -> [binary()].
parse_subqueries(Text, Query) ->
    case decode_string_list(Text) of
        []   -> [];
        List ->
            Deduped = lists:usort(List),
            Capped  = lists:sublist([Query | lists:delete(Query, Deduped)],
                                    ?MAX_SUBQUERIES),
            Capped
    end.

%%====================================================================
%% Internal
%%====================================================================

%% @private
build_prompt(Query) ->
    <<"Decompose this search query into 1 to 5 focused, distinct "
      "sub-queries that together cover its intent. Reply ONLY with a "
      "raw JSON array of strings, no markdown, no explanation.\n"
      "Example: [\"term one\", \"term two\"]\n\n"
      "Query: ", Query/binary>>.

%% @private
%% @doc Decode `Text' as a JSON array of non-empty strings. Returns
%% `[]' on any parse error or if the result isn't a list.
-spec decode_string_list(binary()) -> [binary()].
decode_string_list(Text) ->
    try
        case json:decode(strip_fences(Text)) of
            List when is_list(List) ->
                [S || S <- List, is_binary(S), S =/= <<>>];
            _ ->
                []
        end
    catch _:_ -> []
    end.

%% @private Strip ```json ... ``` / ``` ... ``` markdown fences some
%% models wrap JSON in despite the "no markdown" instruction.
-spec strip_fences(binary()) -> binary().
strip_fences(Text) ->
    T1 = re:replace(Text, <<"^```(json)?\\s*">>, <<"">>,
                    [{return, binary}, multiline]),
    re:replace(T1, <<"\\s*```$">>, <<"">>,
               [{return, binary}, multiline]).
