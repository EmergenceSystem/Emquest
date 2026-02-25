%%%-------------------------------------------------------------------
%%% @doc
%%% queen — LLM Synthesis Dispatcher
%%%
%%% Sits between emquest_handler and em_disco. Receives the raw
%%% aggregated embryo list, picks the configured LLM handler, and
%%% returns a structured response the client can render without any
%%% knowledge of the underlying agents.
%%%
%%% === Response contract (always) ===
%%%
%%% ```json
%%% {
%%%   "answer": "Human-readable synthesis",
%%%   "items":  [
%%%     { "label": "...", "value": "...", "url": "https://..." }
%%%   ]
%%% }
%%% '''
%%% `items' is optional — the LLM decides whether it adds value.
%%% `url'   inside each item is optional.
%%%
%%% === Handler dispatch ===
%%%
%%% The [llm] provider key in emergence.conf selects the handler:
%%%   mistral → mistral_handler  (default)
%%%   ollama  → ollama_handler
%%%   openai  → openai_handler
%%%   claude  → claude_handler
%%%
%%% Each handler must export generate/2 :: (Prompt, Config) ->
%%%   {ok, Binary} | {error, Reason}
%%%
%%% queen builds the prompt and system instruction, then calls the
%%% appropriate handler with its native config map.
%%% The JSON output contract is enforced via the system prompt —
%%% individual handlers are not aware of it.
%%%
%%% === Configuration (emergence.conf) ===
%%%
%%% ```ini
%%% [llm]
%%% provider      = mistral
%%% model         = mistral-small-latest
%%% temperature   = 0.3
%%% system_prompt = You are a helpful assistant. Answer in French.
%%% ; api_key is read from MISTRAL_API_KEY / OPENAI_API_KEY /
%%% ;   ANTHROPIC_API_KEY env variables by each handler.
%%% '''
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(queen).

-export([process/2, expand/2, parse_query_list/1, conf_path/0, parse_conf/1]).

%% JSON output contract appended to every system prompt.
%% Kept separate so the user-facing system_prompt stays clean.
-define(JSON_CONTRACT,
    "\n\nYou must always reply with a raw JSON object — "
    "no markdown, no code fences, no explanation outside the JSON:\n"
    "{\n"
    "  \"answer\": \"concise synthesis (2-4 sentences)\",\n"
    "  \"items\": [\n"
    "    { \"label\": \"title or key\", \"value\": \"description\", \"url\": \"https://...\" }\n"
    "  ]\n"
    "}\n"
    "Rules:\n"
    "- Omit 'items' entirely when a list adds no value "
    "(direct factual answer, already summarised data, etc.).\n"
    "- Include 'items' when there are URLs, records, or structured "
    "data worth surfacing.\n"
    "- 'url' inside an item is optional — include only when genuinely useful.\n"
    "- Never invent information not present in the raw results.\n"
    "- Reply in the same language as the user's query."
).

-define(DEFAULT_SYSTEM_PROMPT,
    "You are a synthesis assistant integrated into a distributed search system. "
    "Be concise and accurate."
).

%%--------------------------------------------------------------------
%% @doc Synthesises raw em_disco results using the configured LLM.
%% @end
%%--------------------------------------------------------------------
-spec process(binary(), list()) -> map().
process(Query, RawResults) ->
    Conf       = read_llm_conf(),
    Provider   = maps:get(provider, Conf, <<"mistral">>),
    SysPrompt  = build_system_prompt(Conf),
    UserPrompt = build_user_prompt(Query, RawResults),
    HandlerConf = handler_conf(Provider, Conf, SysPrompt),

    Result = case Provider of
        <<"mistral">> -> mistral_handler:generate(UserPrompt, HandlerConf);
        <<"ollama">>  -> ollama_handler:generate(UserPrompt, HandlerConf);
        <<"openai">>  -> openai_handler:generate(UserPrompt, HandlerConf);
        <<"claude">>  -> claude_handler:generate(UserPrompt, HandlerConf);
        Unknown ->
            logger:warning("[queen] Unknown provider '~s', falling back to mistral", [Unknown]),
            mistral_handler:generate(UserPrompt, HandlerConf)
    end,

    case Result of
        {ok, Text}      -> parse_llm_response(Text);
        {error, Reason} ->
            logger:error("[queen] LLM error (~s): ~p", [Provider, Reason]),
            fallback_response(RawResults)
    end.

%%====================================================================
%% Prompt building
%%====================================================================

-spec build_system_prompt(map()) -> binary().
build_system_prompt(Conf) ->
    Base    = ensure_binary(maps:get(system_prompt, Conf, ?DEFAULT_SYSTEM_PROMPT)),
    Contract = unicode:characters_to_binary(?JSON_CONTRACT, utf8),
    <<Base/binary, Contract/binary>>.

-spec build_user_prompt(binary(), list()) -> binary().
build_user_prompt(Query, RawResults) ->
    ResultsJson = iolist_to_binary(json:encode(RawResults)),
    <<"User query: ", Query/binary,
      "\n\nRaw agent results (JSON):\n", ResultsJson/binary>>.

%%====================================================================
%% Handler config mapping
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Builds the config map for the target handler.
%%
%% Starts from the handler's own get_env_config/0 so that
%% MISTRAL_API_KEY / OPENAI_API_KEY etc. are picked up automatically,
%% then overlays model / temperature / system_prompt from emergence.conf.
%% API keys are never stored in conf — each handler owns that.
%% @end
%%--------------------------------------------------------------------
-spec handler_conf(binary(), map(), binary()) -> map().
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
        system_prompt => SysPrompt
    }),

    case is_map(Base) of
        true  -> maps:merge(Base, Overrides);
        false -> Overrides
    end.

%%====================================================================
%% Response parsing
%%====================================================================

-spec parse_llm_response(binary()) -> map().
parse_llm_response(Text) ->
    Cleaned = strip_code_fences(Text),
    try
        Decoded = json:decode(Cleaned),
        case maps:is_key(<<"answer">>, Decoded) of
            true  -> Decoded;
            false -> #{<<"answer">> => Text}
        end
    catch _:_ ->
        #{<<"answer">> => Text}
    end.

-spec strip_code_fences(binary()) -> binary().
strip_code_fences(Text) ->
    T1 = re:replace(Text, <<"^```(json)?\\s*">>, <<"">>,
                    [{return, binary}, multiline]),
    re:replace(T1, <<"\\s*```$">>, <<"">>, [{return, binary}, multiline]).

%%====================================================================
%% Fallback
%%====================================================================

-spec fallback_response(list()) -> map().
fallback_response(RawResults) ->
    Items = lists:filtermap(fun(Embryo) ->
        Props = maps:get(<<"properties">>, Embryo, #{}),
        case map_size(Props) of
            0 -> false;
            _ ->
                Url   = maps:get(<<"url">>,    Props, null),
                Label = maps:get(<<"title">>,  Props,
                            maps:get(<<"label">>, Props, <<"Result">>)),
                Value = maps:get(<<"resume">>, Props,
                            maps:get(<<"value">>, Props, <<>>)),
                {true, #{<<"label">> => Label,
                         <<"value">> => Value,
                         <<"url">>   => Url}}
        end
    end, RawResults),
    Base = #{<<"answer">> => <<"LLM unavailable — raw results below.">>},
    case Items of
        [] -> Base;
        _  -> Base#{<<"items">> => Items}
    end.

%%--------------------------------------------------------------------
%% @doc Expands a complex query into simpler search sub-queries.
%%
%% Returns the original query plus extracted keywords/sub-terms.
%% When Expand is false (short/simple query), returns [Query] as-is.
%% @end
%%--------------------------------------------------------------------
-spec expand(binary(), boolean()) -> [binary()].
expand(Query, false) -> [Query];
expand(Query, true) ->
    Conf   = read_llm_conf(),
    Prompt = <<"Extract 2 to 3 simple search keywords or sub-queries from "
               "this complex query. Reply ONLY with a JSON array of strings, "
               "nothing else. Example: [\"term1\", \"term2\"]\n\n"
               "Query: ", Query/binary>>,
    HandlerConf = handler_conf(
        maps:get(provider, Conf, <<"mistral">>),
        Conf#{system_prompt => <<"You extract search keywords. Reply only with a JSON array.">>},
        <<"You extract search keywords. Reply only with a JSON array.">>
    ),
    SubQueries = case mistral_handler:generate(Prompt, HandlerConf) of
        {ok, Text} -> parse_query_list(Text);
        _          -> []
    end,
    %% Always include the original query
    lists:usort([Query | SubQueries]).

-spec parse_query_list(binary()) -> [binary()].
parse_query_list(Text) ->
    Cleaned = strip_code_fences(Text),
    try
        List = json:decode(Cleaned),
        [Q || Q <- List, is_binary(Q)]
    catch _:_ -> []
    end.

%%====================================================================
%% Configuration
%%====================================================================

-spec read_llm_conf() -> map().
read_llm_conf() ->
    case conf_path() of
        undefined -> #{};
        Path ->
            case file:read_file(Path) of
                {ok, Bin} -> parse_llm_section(parse_conf(Bin));
                _         -> #{}
            end
    end.

-spec parse_llm_section(map()) -> map().
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
%% @doc Returns the path to emergence.conf, or undefined.
%% Exported for reuse by emquest_handler.
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
%%   #{ "section" => #{ "key" => "value" } }
%% Exported for reuse by emquest_handler.
%% @end
%%--------------------------------------------------------------------
-spec parse_conf(binary()) -> map().
parse_conf(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    {Map, _} = lists:foldl(fun parse_line/2, {#{}, ""}, Lines),
    Map.

%% Skip comment lines (starting with ; or #)
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

-spec ensure_binary(term()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L)   -> list_to_binary(L);
ensure_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8);
ensure_binary(_)                   -> <<>>.
