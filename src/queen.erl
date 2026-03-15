%%%-------------------------------------------------------------------
%%% @doc
%%% queen — LLM Query Expander and Result Ranker
%%%
%%% Two responsibilities:
%%%
%%%   expand/1     — given a user query, returns a list of simpler
%%%                  sub-queries to fan out to disco.  For short/simple
%%%                  queries returns [Query] as-is.
%%%
%%%   rank/2       — given the original query and the full deduplicated
%%%                  result list, asks the LLM to return a sorted order
%%%                  (most relevant first).  ALL results are kept —
%%%                  nothing is hidden.
%%%
%%%   synthesize/2 — generates a short prose answer from the top results.
%%%
%%% LLM ranking contract:
%%%
%%%   The LLM receives the list with indices and returns ONLY a JSON
%%%   array of those indices in relevance order, e.g.: [2, 0, 4, 1, 3]
%%%   Each ranked item gets a score (3 = top, 0 = tail) based on its
%%%   position in the returned list.
%%%
%%% Configuration (emergence.conf):
%%%
%%%   [llm]
%%%   provider      = mistral
%%%   model         = mistral-small-latest
%%%   temperature   = 0.1
%%%   system_prompt = ...
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(queen).

-export([expand/1, rank/2, synthesize/2, conf_path/0, parse_conf/1]).

-define(DEFAULT_SYSTEM_PROMPT,
    "You are a search assistant. Be concise and precise.").

%%====================================================================
%% Query expansion
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Expands a user query into simpler search sub-queries.
%%
%% For queries under 25 chars, skips expansion and returns [Query].
%% Otherwise asks the LLM for 2-3 relevant sub-queries and always
%% prepends the original query so it is always searched as-is.
%%
%% The original query is placed first in the returned list.
%% Sub-queries are deduplicated but their relative order is preserved
%% (usort is NOT used on the full list to avoid reordering the head).
%% @end
%%--------------------------------------------------------------------
-spec expand(binary()) -> [binary()].
expand(Query) when byte_size(Query) < 25 ->
    [Query];
expand(Query) ->
    Conf   = read_llm_conf(),
    Prompt = <<"Extract 2 to 3 simple search keywords or sub-queries from "
               "this query. Reply ONLY with a raw JSON array of strings, "
               "no markdown, no explanation.\n"
               "Example: [\"term one\", \"term two\"]\n\n"
               "Query: ", Query/binary>>,
    HandlerConf = handler_conf(
        maps:get(provider, Conf, <<"mistral">>),
        Conf,
        <<"You extract search keywords. Reply only with a JSON array of strings.">>
    ),
    SubQueries = case call_handler(maps:get(provider, Conf, <<"mistral">>),
                                   Prompt, HandlerConf) of
        {ok, Text} -> parse_json_list(Text);
        _          -> []
    end,
    %% The original query always comes first.
    %% Sub-queries are deduplicated; the original is removed from
    %% the sub-list before prepending so it is not duplicated.
    Deduped = lists:usort(SubQueries),
    [Query | lists:delete(Query, Deduped)].

%%====================================================================
%% Synthesis
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Generates a short prose answer for the query.
%%
%% Called after ranking so the LLM has context from the top results.
%% Uses the user-configured system_prompt (language, tone, etc.).
%% Returns plain text binary — no JSON, goes straight to the client.
%% @end
%%--------------------------------------------------------------------
-spec synthesize(binary(), [map()]) -> binary().
synthesize(Query, RankedItems) ->
    Conf      = read_llm_conf(),
    Provider  = maps:get(provider, Conf, <<"mistral">>),
    SysPrompt = ensure_binary(maps:get(system_prompt, Conf, ?DEFAULT_SYSTEM_PROMPT)),

    %% Pass only the top 5 results as context to keep the prompt small.
    TopN = lists:sublist(RankedItems, 5),
    Context = iolist_to_binary(json:encode(
        [begin
            Props = maps:get(<<"properties">>, Item, Item),
            Label = maps:get(<<"title">>,  Props, maps:get(<<"label">>,  Props, <<>>)),
            Value = maps:get(<<"resume">>, Props, maps:get(<<"value">>,  Props, <<>>)),
            #{<<"l">> => Label, <<"v">> => Value}
         end || Item <- TopN]
    )),

    Prompt = <<"Answer or summarise the following query in 2-4 sentences. "
               "Use the provided search results as context. "
               "Reply in plain text only — no JSON, no markdown, no bullet points.\n\n"
               "Query: ", Query/binary, "\n\n"
               "Top results context:\n", Context/binary>>,

    HandlerConf = handler_conf(Provider, Conf, SysPrompt),
    case call_handler(Provider, Prompt, HandlerConf) of
        {ok, Text} -> Text;
        _          -> <<>>
    end.

%%====================================================================
%% Result ranking
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Ranks a result list by relevance to the query.
%%
%% Sends the list with numeric indices to the LLM, which returns those
%% indices sorted by relevance (most relevant first).
%% ALL items are kept — only the order changes.
%% Items get a score 0-3 based on their rank quartile.
%% @end
%%--------------------------------------------------------------------
-spec rank(binary(), [map()]) -> [map()].
rank(_Query, []) -> [];
rank(Query, Items) ->
    Conf = read_llm_conf(),

    %% Build a compact indexed representation for the LLM prompt.
    Indexed = lists:zip(lists:seq(0, length(Items) - 1), Items),
    IndexedJson = iolist_to_binary(json:encode(
        [begin
            Props = maps:get(<<"properties">>, Item, Item),
            Label = maps:get(<<"title">>,  Props,
                        maps:get(<<"label">>,  Props, <<>>)),
            Value = maps:get(<<"resume">>, Props,
                        maps:get(<<"value">>,  Props, <<>>)),
            #{<<"i">> => I, <<"l">> => Label, <<"v">> => Value}
         end || {I, Item} <- Indexed]
    )),

    Prompt = <<"You receive search results and a query. "
               "Return ONLY a JSON array of the result indices sorted "
               "by relevance to the query (most relevant first). "
               "Keep ALL indices. No explanation, no markdown.\n"
               "Example for 4 results: [2, 0, 3, 1]\n\n"
               "Query: ", Query/binary, "\n\n"
               "Results:\n", IndexedJson/binary>>,

    HandlerConf = handler_conf(
        maps:get(provider, Conf, <<"mistral">>),
        %% Low temperature for deterministic ranking.
        Conf#{temperature => 0.1},
        <<"You rank search results. Reply only with a JSON array of integers.">>
    ),

    RankedIndices = case call_handler(maps:get(provider, Conf, <<"mistral">>),
                                      Prompt, HandlerConf) of
        {ok, Text} ->
            Parsed  = parse_json_integers(Text),
            %% Append any indices the LLM omitted so no item is lost.
            All     = lists:seq(0, length(Items) - 1),
            Missing = All -- Parsed,
            Parsed ++ Missing;
        _ ->
            lists:seq(0, length(Items) - 1)
    end,

    %% Re-order items and inject a 0-3 score based on rank position.
    Total    = length(RankedIndices),
    ItemsArr = list_to_tuple(Items),
    lists:filtermap(fun({Pos, Idx}) ->
        case Idx >= 0 andalso Idx < tuple_size(ItemsArr) of
            true ->
                Item  = element(Idx + 1, ItemsArr),
                Score = score_for_position(Pos, Total),
                {true, Item#{<<"score">> => Score}};
            false -> false
        end
    end, lists:zip(lists:seq(0, length(RankedIndices) - 1), RankedIndices)).

%% Maps a 0-based position to a 0-3 relevance score by quartile.
score_for_position(_Pos, Total) when Total =< 1 -> 3;
score_for_position(Pos, Total) ->
    Quartile = (Pos * 4) div Total,
    max(0, 3 - Quartile).

%%====================================================================
%% LLM dispatch
%%====================================================================

call_handler(<<"mistral">>, Prompt, Conf) -> mistral_handler:generate(Prompt, Conf);
call_handler(<<"ollama">>,  Prompt, Conf) -> ollama_handler:generate(Prompt, Conf);
call_handler(<<"openai">>,  Prompt, Conf) -> openai_handler:generate(Prompt, Conf);
call_handler(<<"claude">>,  Prompt, Conf) -> claude_handler:generate(Prompt, Conf);
call_handler(_, Prompt, Conf)             -> mistral_handler:generate(Prompt, Conf).

%%--------------------------------------------------------------------
%% @private
%% @doc Builds a handler config map from emergence.conf + env vars.
%%
%% Starts from the handler's get_env_config/0 (picks up API keys from
%% the environment) then overlays conf file values and the given
%% system prompt.
%% @end
%%--------------------------------------------------------------------
handler_conf(Provider, Conf, SysPrompt) ->
    Base = case Provider of
        <<"mistral">> -> mistral_handler:get_env_config();
        <<"ollama">>  -> (catch ollama_handler:get_env_config());
        <<"openai">>  -> (catch openai_handler:get_env_config());
        <<"claude">>  -> (catch claude_handler:get_env_config());
        _             -> mistral_handler:get_env_config()
    end,
    Overrides = maps:filter(fun(_, V) -> V =/= undefined end, #{
        model         => maps:get(model,       Conf, undefined),
        temperature   => maps:get(temperature, Conf, undefined),
        system_prompt => ensure_binary(SysPrompt)
    }),
    case is_map(Base) of
        true  -> maps:merge(Base, Overrides);
        false -> Overrides
    end.

%%====================================================================
%% JSON parsing helpers
%%====================================================================

parse_json_list(Text) ->
    try
        List = json:decode(strip_fences(Text)),
        [Q || Q <- List, is_binary(Q)]
    catch _:_ -> [] end.

parse_json_integers(Text) ->
    try
        List = json:decode(strip_fences(Text)),
        [I || I <- List, is_integer(I)]
    catch _:_ -> [] end.

%% Strips markdown code fences that some LLMs add around JSON output.
strip_fences(Text) ->
    T1 = re:replace(Text, <<"^```(json)?\\s*">>, <<"">>,
                    [{return, binary}, multiline]),
    re:replace(T1, <<"\\s*```$">>, <<"">>,
               [{return, binary}, multiline]).

%%====================================================================
%% Configuration
%%====================================================================

read_llm_conf() ->
    case conf_path() of
        undefined -> #{};
        Path ->
            case file:read_file(Path) of
                {ok, Bin} -> parse_llm_section(parse_conf(Bin));
                _         -> #{}
            end
    end.

parse_llm_section(ConfMap) ->
    Section = maps:get("llm", ConfMap, #{}),
    maps:fold(fun(K, V, Acc) ->
        Value = case K of
            "temperature" ->
                try list_to_float(V)
                catch _:_ ->
                    try float(list_to_integer(V))
                    catch _:_ -> 0.3 end
                end;
            _ -> list_to_binary(V)
        end,
        Acc#{list_to_atom(K) => Value}
    end, #{}, Section).

%%--------------------------------------------------------------------
%% @doc Returns the path to emergence.conf.
%% Exported so emquest_handler can reuse it.
%% @end
%%--------------------------------------------------------------------
-spec conf_path() -> string() | undefined.
conf_path() ->
    case {os:getenv("HOME"), os:getenv("APPDATA"), os:type()} of
        {false, false, _}    -> undefined;
        {false, AppData, _}  ->
            filename:join([AppData, "emergence", "emergence.conf"]);
        {Home, _, {unix, _}} ->
            filename:join([Home, ".config", "emergence", "emergence.conf"]);
        {Home, _, _}         ->
            filename:join([Home, "AppData", "Roaming", "emergence",
                           "emergence.conf"])
    end.

%%--------------------------------------------------------------------
%% @doc Parses an INI-style config file into a nested map.
%% Exported so emquest_handler can reuse it.
%% @end
%%--------------------------------------------------------------------
-spec parse_conf(binary()) -> map().
parse_conf(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    {Map, _} = lists:foldl(fun parse_line/2, {#{}, ""}, Lines),
    Map.

parse_line(<<";", _/binary>>, Acc) -> Acc;
parse_line(<<"#", _/binary>>, Acc) -> Acc;
parse_line(<<"[", Rest/binary>>, {Map, _Sec}) ->
    Sec = string:trim(binary_to_list(binary:part(Rest, 0, byte_size(Rest) - 1))),
    {Map#{Sec => #{}}, Sec};
parse_line(Line, {Map, Sec}) when Sec =/= "" ->
    case binary:split(Line, <<"=">>) of
        [K, V] ->
            Key = string:trim(binary_to_list(K)),
            Val = string:trim(binary_to_list(V)),
            {Map#{Sec => maps:put(Key, Val, maps:get(Sec, Map, #{}))}, Sec};
        _ -> {Map, Sec}
    end;
parse_line(_, Acc) -> Acc.

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8);
ensure_binary(_)                   -> <<>>.
