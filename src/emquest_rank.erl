%%%-------------------------------------------------------------------
%%% @doc emquest_rank - grouping, hybrid relevance scoring, and MMR.
%%% Pure (except the [rank] config file read). Turns tagged fan-out
%%% items + a query into a ranked sid list, and diversifies a ranked
%%% list by Maximal Marginal Relevance.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_rank).

-export([normalize/1, words/1, lex_score/3]).

%% @doc Lowercase + collapse whitespace + trim.
-spec normalize(binary()) -> binary().
normalize(B) when is_binary(B) ->
    L = string:lowercase(B),
    C = re:replace(L, <<"\\s+">>, <<" ">>, [global, unicode, {return, binary}]),
    string:trim(C);
normalize(_) -> <<>>.

%% @doc Query words >= 2 chars.
-spec words(binary()) -> [binary()].
words(QNorm) ->
    [W || W <- binary:split(QNorm, <<" ">>, [global, trim_all]),
          byte_size(W) >= 2].

%% @doc Lexical relevance: field-weighted word coverage + exact-phrase bonus.
-spec lex_score(binary(), [binary()], map()) -> float().
lex_score(QNorm, QWords, Item) ->
    P = maps:get(<<"properties">>, Item, Item),
    Title = normalize(field(P, [<<"title">>, <<"label">>])),
    Body  = normalize(field(P, [<<"resume">>, <<"value">>])),
    Url   = normalize(maps:get(<<"url">>, P, <<>>)),
    Base = 3.0 * cover(Title, QWords)
         + 1.5 * cover(Body, QWords)
         + 0.5 * cover(Url, QWords),
    Phrase = case length(QWords) >= 2 andalso
                  (contains(Title, QNorm) orelse contains(Body, QNorm)) of
                 true  -> phrase_boost();
                 false -> 0.0
             end,
    Base + Phrase.

%% @private fraction of query words present in Text.
cover(_Text, []) -> 0.0;
cover(Text, QWords) ->
    N = length([W || W <- QWords, contains(Text, W)]),
    N / length(QWords).

%% @private
contains(_Text, <<>>) -> false;
contains(Text, Sub) -> binary:match(Text, Sub) =/= nomatch.

%% @private first present, non-empty field.
field(P, [K | Ks]) ->
    case maps:get(K, P, <<>>) of
        V when is_binary(V), byte_size(V) > 0 -> V;
        _ -> field(P, Ks)
    end;
field(_P, []) -> <<>>.

%% @private [rank] phrase_boost, default 0.5.
phrase_boost() -> 0.5.
