%%%-------------------------------------------------------------------
%%% @doc emquest_preview — fetch a URL and extract a meaningful
%%% description for drift cards.
%%%
%%% Two-pass strategy:
%%%   Pass 1 — meta tags: og:description, then meta name=description.
%%%            Fast; present on most sites but often short or SEO-y.
%%%   Pass 2 — body text: concatenate <p> content found inside <article>,
%%%            <main>, or anywhere if neither is present. Strips inline
%%%            tags. Slower but captures the real article intro.
%%%
%%% The result with the higher "substance score" (length × non-fluff
%%% bonus) is returned, truncated to 320 chars. Times out in 5 s. All
%%% outbound fetches go through the SSRF guard (`emquest_safeurl').
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_preview).

-export([fetch/1]).
-export([describe/1]).   %% exported for offline extraction tests

%% @doc The pure extraction step: pick the best description from raw HTML,
%% without any network fetch. `fetch/1' = safe_get + `describe/1'.
-spec describe(binary()) -> binary().
describe(Html) -> best_description(Html).

-spec fetch(binary()) -> {ok, binary()} | {error, term()}.
fetch(<<>>) -> {error, empty_url};
fetch(Url) ->
    case emquest_safeurl:safe_get(Url,
             [{"User-Agent", "Mozilla/5.0 (compatible; Emquest/1.0)"}],
             [{timeout, 5000}]) of
        {ok, Body} -> {ok, best_description(Body)};
        {error, R} -> {error, R}
    end.

%% @private Pick the more informative of the meta description and body text.
-spec best_description(binary()) -> binary().
best_description(Html) ->
    Meta = extract_meta(Html),
    Body = extract_body_text(Html),
    case substance_score(Meta) >= substance_score(Body) of
        true  -> truncate(Meta, 320);
        false -> truncate(Body, 320)
    end.

%% @private Score a candidate description by length, penalising SEO fluff.
%% Short texts (<60 chars) score 0 so the other candidate wins by default.
-spec substance_score(binary()) -> non_neg_integer().
substance_score(<<>>) -> 0;
substance_score(B) ->
    Len = byte_size(B),
    case Len < 60 of
        true  -> 0;
        false ->
            Lower = string:lowercase(binary_to_list(B)),
            FluffPhrases = ["discover", "learn more", "click here",
                            "sign up", "subscribe", "cookie", "privacy policy",
                            "all rights reserved", "©"],
            Penalty = lists:sum([5 || P <- FluffPhrases,
                                      string:find(Lower, P) =/= nomatch]),
            max(0, Len - Penalty * 10)
    end.

%% @private Extract og:description or meta name=description from <head>.
-spec extract_meta(binary()) -> binary().
extract_meta(Html) ->
    Patterns = [
        <<"property=[\"']og:description[\"'][^>]*content=[\"']([^\"']{20,})[\"']">>,
        <<"content=[\"']([^\"']{20,})[\"'][^>]*property=[\"']og:description[\"']">>,
        <<"name=[\"']description[\"'][^>]*content=[\"']([^\"']{20,})[\"']">>,
        <<"content=[\"']([^\"']{20,})[\"'][^>]*name=[\"']description[\"']">>
    ],
    extract_first_match(Html, Patterns).

%% @private Extract and join leading paragraph text from <article> or <main>.
%% Falls back to any <p> tags in the document if neither landmark is found.
-spec extract_body_text(binary()) -> binary().
extract_body_text(Html) ->
    Region = case extract_region(Html, <<"article">>) of
        <<>> -> case extract_region(Html, <<"main">>) of
            <<>> -> Html;
            M    -> M
        end;
        A -> A
    end,
    Paragraphs = extract_paragraphs(Region),
    join_paragraphs(Paragraphs, <<>>, 0).

%% @private Extract the inner HTML of the first <Tag>…</Tag> block.
-spec extract_region(binary(), binary()) -> binary().
extract_region(Html, Tag) ->
    Pat = <<"<", Tag/binary, "[^>]*>([\\s\\S]*?)</", Tag/binary, ">">>,
    case re:run(Html, Pat, [{capture, [1], binary}, caseless]) of
        {match, [M]} -> M;
        _            -> <<>>
    end.

%% @private Extract text content from all <p> tags, stripping inline tags.
-spec extract_paragraphs(binary()) -> [binary()].
extract_paragraphs(Html) ->
    case re:run(Html, <<"<p[^>]*>([\\s\\S]*?)</p>">>,
                [global, {capture, [1], binary}, caseless]) of
        {match, Groups} ->
            [strip_tags(trim_ws(P)) || [P] <- Groups,
             byte_size(trim_ws(P)) > 40];
        _ -> []
    end.

%% @private Join paragraphs with a space until we have enough text.
-spec join_paragraphs([binary()], binary(), non_neg_integer()) -> binary().
join_paragraphs([], Acc, _) -> Acc;
join_paragraphs(_, Acc, N) when N >= 3 -> Acc;
join_paragraphs([P | Rest], <<>>, N) ->
    join_paragraphs(Rest, P, N + 1);
join_paragraphs([P | Rest], Acc, N) ->
    join_paragraphs(Rest, <<Acc/binary, " ", P/binary>>, N + 1).

%% @private Remove all HTML tags from a binary, collapsing whitespace.
-spec strip_tags(binary()) -> binary().
strip_tags(B) ->
    NoTags = re:replace(B, <<"<[^>]+>">>, <<" ">>, [global, {return, binary}]),
    Collapsed = re:replace(NoTags, <<"\\s+">>, <<" ">>, [global, {return, binary}]),
    trim_ws(Collapsed).

%% @private Return the first match from a list of regex patterns.
-spec extract_first_match(binary(), [binary()]) -> binary().
extract_first_match(_Html, []) -> <<>>;
extract_first_match(Html, [Pat | Rest]) ->
    case re:run(Html, Pat, [{capture, [1], binary}, caseless]) of
        {match, [M]} ->
            Trimmed = trim_ws(M),
            case byte_size(Trimmed) > 20 of
                true  -> Trimmed;
                false -> extract_first_match(Html, Rest)
            end;
        _ -> extract_first_match(Html, Rest)
    end.

trim_ws(B) ->
    re:replace(B, <<"^\\s+|\\s+$">>, <<>>, [global, {return, binary}]).

truncate(B, Max) when byte_size(B) =< Max -> B;
truncate(B, Max) ->
    <<Prefix:Max/binary, _/binary>> = B,
    <<Prefix/binary, "…">>.
