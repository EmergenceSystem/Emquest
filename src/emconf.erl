%%%-------------------------------------------------------------------
%%% @doc emconf — one reader for `emergence.conf'.
%%%
%%% Every module used to re-read and re-parse `emergence.conf' on each
%%% tunable lookup (em_agent, agent_router, agent_judge, agent_dedup,
%%% emquest_rank, emquest_handler, queen), so a single query triggered
%%% dozens of file reads + parses. This module parses the file once and
%%% caches the result in `persistent_term', re-reading only when the
%%% file's mtime changes — so live edits are still picked up.
%%%
%%% Typed getters (`get_int'/`get_float'/`get_bool'/`get_string') fold
%%% the per-module coercion helpers into one place. Parsing itself is
%%% still `queen:parse_conf/1' (the tested INI parser).
%%% @end
%%%-------------------------------------------------------------------
-module(emconf).
-include_lib("kernel/include/file.hrl").

-export([section/1, get_int/3, get_float/3, get_bool/3, get_string/3, flush/0]).

-define(CACHE, emconf_cache).

%%--------------------------------------------------------------------
%% @doc The `[Section]' map (`#{string() => string()}'), or `#{}'.
%%--------------------------------------------------------------------
-spec section(string()) -> #{string() => string()}.
section(Name) ->
    maps:get(Name, all(), #{}).

%%--------------------------------------------------------------------
%% @doc `[Section] Key' as a positive integer, else `Default'.
%%--------------------------------------------------------------------
-spec get_int(string(), string(), integer()) -> integer().
get_int(Section, Key, Default) ->
    case raw(Section, Key) of
        undefined -> Default;
        V when is_list(V) ->
            case string:to_integer(V) of
                {I, _} when is_integer(I), I > 0 -> I;
                _ -> Default
            end;
        _ -> Default
    end.

%%--------------------------------------------------------------------
%% @doc `[Section] Key' as a float (accepts an integer literal too),
%% else `Default'.
%%--------------------------------------------------------------------
-spec get_float(string(), string(), float()) -> float().
get_float(Section, Key, Default) ->
    case raw(Section, Key) of
        undefined -> Default;
        V when is_list(V) ->
            case string:to_float(V) of
                {F, _} when is_float(F) -> F;
                _ ->
                    case string:to_integer(V) of
                        {I, _} when is_integer(I) -> float(I);
                        _ -> Default
                    end
            end;
        _ -> Default
    end.

%%--------------------------------------------------------------------
%% @doc `[Section] Key' as a boolean: an explicit `off' is false, any
%% other value is true; a missing key falls back to `Default'.
%%--------------------------------------------------------------------
-spec get_bool(string(), string(), boolean()) -> boolean().
get_bool(Section, Key, Default) ->
    case raw(Section, Key) of
        undefined -> Default;
        "off"     -> false;
        _         -> true
    end.

%%--------------------------------------------------------------------
%% @doc `[Section] Key' as a raw string, else `Default'.
%%--------------------------------------------------------------------
-spec get_string(string(), string(), string()) -> string().
get_string(Section, Key, Default) ->
    case raw(Section, Key) of
        undefined -> Default;
        V         -> V
    end.

%% @doc Drop the cached parse (next lookup re-reads the file).
-spec flush() -> ok.
flush() ->
    persistent_term:erase(?CACHE),
    ok.

%%====================================================================
%% Internal
%%====================================================================

%% @private
raw(Section, Key) ->
    maps:get(Key, section(Section), undefined).

%% @private Full parsed conf, cached in persistent_term keyed by mtime.
-spec all() -> map().
all() ->
    case queen:conf_path() of
        undefined -> #{};
        Path ->
            %% Key the cache on BOTH path and mtime: the path can change
            %% (e.g. HOME differs between test cases) while two files share
            %% an mtime (second resolution, or both absent -> `none').
            Key = {Path, mtime(Path)},
            case persistent_term:get(?CACHE, undefined) of
                {Key, Map} -> Map;
                _ ->
                    Map = case file:read_file(Path) of
                              {ok, Bin} -> queen:parse_conf(Bin);
                              _         -> #{}
                          end,
                    persistent_term:put(?CACHE, {Key, Map}),
                    Map
            end
    end.

%% @private
mtime(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{mtime = M}} -> M;
        _                           -> none
    end.
