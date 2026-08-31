%%%-------------------------------------------------------------------
%%% @doc emquest_rank - grouping, hybrid relevance scoring, and MMR.
%%% Pure (except the [rank] config file read). Turns tagged fan-out
%%% items + a query into a ranked sid list, and diversifies a ranked
%%% list by Maximal Marginal Relevance.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_rank).

-export([normalize/1, words/1, lex_score/3, rank/3]).

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

%% @doc Group tagged items by URL, hybrid-score each group, sort best-first.
%% Returns {SortedSids, ScoresMap} exactly like the old aggregate_and_rank/3.
-spec rank(binary(), list(), binary()) -> {[non_neg_integer()], map()}.
rank(Query, TaggedItems, QueryVec) ->
    QNorm  = normalize(Query),
    QWords = words(QNorm),
    Groups = group_by_url(TaggedItems),
    Raw = maps:fold(fun(_Key, Group, Acc) ->
        {RepSid, _, _, _, _} = hd(Group),
        Lex  = lists:max([lex_score(QNorm, QWords, I) || {_, I, _, _, _} <- Group]),
        Vec  = lists:max([hash_vec(QueryVec, I) || {_, I, _, _, _} <- Group]),
        Auth = auth(Group),
        [{RepSid, Lex, Vec, Auth} | Acc]
    end, [], Groups),
    Scored = fuse(Raw),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end, Scored),
    SortedSids = [S || {S, _} <- Sorted],
    ScoresMap  = maps:from_list([{integer_to_binary(S), Sc} || {S, Sc} <- Sorted]),
    {SortedSids, ScoresMap}.

%% @private group by dedup key (url, else title), keep lowest-Sid rep first.
group_by_url(TaggedItems) ->
    lists:foldl(fun({Sid, Item, Rank, SubQ, Trust}, Acc) ->
        Key = dedup_key(Item),
        maps:update_with(Key, fun(E) -> [{Sid, Item, Rank, SubQ, Trust} | E] end,
                         [{Sid, Item, Rank, SubQ, Trust}], Acc)
    end, #{}, lists:reverse(TaggedItems)).

%% @private
dedup_key(Item) ->
    P = maps:get(<<"properties">>, Item, Item),
    case maps:get(<<"url">>, P, <<>>) of
        U when is_binary(U), byte_size(U) > 0 -> {url, U};
        _ -> {title, field(P, [<<"title">>, <<"label">>])}
    end.

%% @private hash-vector similarity of the query vs item text (cheap, no hf).
%% from_capabilities/1 gives normalized unit vectors, so their dot product
%% is the cosine. This is item_vec_score/2 moved out of the handler.
hash_vec(QueryVec, Item) ->
    P = maps:get(<<"properties">>, Item, Item),
    Words = [V || K <- [<<"title">>, <<"label">>, <<"resume">>,
                        <<"value">>, <<"description">>],
                  V <- [maps:get(K, P, <<>>)],
                  is_binary(V), byte_size(V) > 0],
    case Words of
        [] -> 0.0;
        _  -> dot_prod(QueryVec, em_filter_vec:from_capabilities(Words))
    end.

%% @private dot product of two f32 little-endian unit vectors (= cosine).
dot_prod(A, B) ->
    FA = [F || <<F:32/float-little>> <= A],
    FB = [F || <<F:32/float-little>> <= B],
    lists:foldl(fun({X, Y}, Acc) -> Acc + X * Y end, 0.0, lists:zip(FA, FB)).

%% @private source authority: occurrence + trust-RRF + sub-query coverage.
auth(Group) ->
    Occ = length(Group),
    RRF = lists:sum([Trust / (R + 61) || {_, _, R, _, Trust} <- Group]),
    SubQs = length(lists:usort([SQ || {_, _, _, SQ, _} <- Group])),
    float(Occ) + RRF * 2.0 + float(SubQs).

%% @private min-max normalize each signal, weighted sum.
fuse(Raw) ->
    NL = minmax([L || {_, L, _, _} <- Raw]),
    NV = minmax([V || {_, _, V, _} <- Raw]),
    NA = minmax([A || {_, _, _, A} <- Raw]),
    {WL, WV, WA} = weights(),
    [{Sid, WL * NL(L) + WV * NV(V) + WA * NA(A)} || {Sid, L, V, A} <- Raw].

%% @private returns a normaliser fun over the given sample.
minmax([]) -> fun(_) -> 0.0 end;
minmax(Xs) ->
    Mn = lists:min(Xs), Mx = lists:max(Xs), Rng = Mx - Mn,
    case Rng > 0 of
        true  -> fun(X) -> (X - Mn) / Rng end;
        false -> fun(_) -> 0.0 end
    end.

%% @private [rank] weights, defaults lexical-dominant.
weights() -> {0.6, 0.25, 0.15}.

%% @private [rank] phrase_boost, default 0.5.
phrase_boost() -> 0.5.
