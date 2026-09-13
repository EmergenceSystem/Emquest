-module(emquest_preview_tests).
-include_lib("eunit/include/eunit.hrl").

meta_og_description_test() ->
    Html = <<"<html><head>"
             "<meta property=\"og:description\" content=\"A precise and "
             "sufficiently long summary of the page content here.\">"
             "</head><body><p>x</p></body></html>">>,
    D = emquest_preview:describe(Html),
    ?assert(binary:match(D, <<"precise and sufficiently long summary">>) =/= nomatch).

body_paragraph_fallback_test() ->
    %% No meta; a long article paragraph should be picked up.
    Html = <<"<html><body><article><p>"
             "This is the real article introduction with more than forty "
             "characters of genuine body content worth extracting.</p>"
             "</article></body></html>">>,
    D = emquest_preview:describe(Html),
    ?assert(binary:match(D, <<"real article introduction">>) =/= nomatch).

strips_inline_tags_test() ->
    Html = <<"<article><p>Hello <b>bold</b> and <a href=\"x\">link</a> world "
             "with plenty of extra length to pass the sixty char floor.</p>"
             "</article>">>,
    D = emquest_preview:describe(Html),
    ?assertEqual(nomatch, binary:match(D, <<"<b>">>)),
    ?assert(binary:match(D, <<"bold">>) =/= nomatch).

empty_html_is_empty_test() ->
    ?assertEqual(<<>>, emquest_preview:describe(<<"<html><head></head><body></body></html>">>)).

truncates_long_description_test() ->
    Long = list_to_binary(lists:duplicate(1000, $a)),
    Html = <<"<article><p>", Long/binary, "</p></article>">>,
    D = emquest_preview:describe(Html),
    %% 320 chars + the "…" ellipsis (3 UTF-8 bytes).
    ?assert(byte_size(D) =< 320 + 3).
