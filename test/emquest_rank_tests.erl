-module(emquest_rank_tests).
-include_lib("eunit/include/eunit.hrl").

item(Title, Resume) ->
    Url = <<"http://x/", (integer_to_binary(erlang:phash2(Title)))/binary>>,
    #{<<"properties">> => #{<<"title">> => Title, <<"resume">> => Resume,
                            <<"url">> => Url}}.

normalize_test() ->
    ?assertEqual(<<"tarte aux pommes">>,
                 emquest_rank:normalize(<<"  Tarte   AUX  Pommes ">>)).

lex_phrase_beats_words_test() ->
    Q = <<"tarte aux pommes">>,
    QN = emquest_rank:normalize(Q),
    QW = emquest_rank:words(QN),
    Phrase  = emquest_rank:lex_score(QN, QW, item(<<"Tarte aux pommes maison">>, <<>>)),
    Scatter = emquest_rank:lex_score(QN, QW, item(<<"Marche aux pommes">>, <<"une tarte ailleurs">>)),
    Partial = emquest_rank:lex_score(QN, QW, item(<<"Recette de tarte">>, <<>>)),
    ?assert(Phrase > Scatter),
    ?assert(Scatter > Partial).

lex_title_beats_body_test() ->
    Q = <<"pomme">>, QN = emquest_rank:normalize(Q), QW = emquest_rank:words(QN),
    InTitle = emquest_rank:lex_score(QN, QW, item(<<"pomme">>, <<"rien">>)),
    InBody  = emquest_rank:lex_score(QN, QW, item(<<"rien">>, <<"une pomme ici">>)),
    ?assert(InTitle > InBody).

tagged(Sid, Title, Rank) ->
    {Sid, item(Title, <<>>), Rank, <<"q">>, 1.0}.

rank_phrase_first_test() ->
    Vec = em_filter_vec:from_capabilities([<<"tarte">>, <<"pomme">>]),
    Tagged = [tagged(1, <<"Marche aux pommes">>, 0),
              tagged(2, <<"Tarte aux pommes maison">>, 0),
              tagged(3, <<"Recette de tarte">>, 0)],
    {Sids, Scores} = emquest_rank:rank(<<"tarte aux pommes">>, Tagged, Vec),
    ?assertEqual(2, hd(Sids)),
    ?assert(is_map(Scores)),
    ?assertEqual(3, length(Sids)).

rank_single_item_test() ->
    Vec = em_filter_vec:from_capabilities([<<"x">>]),
    {Sids, _} = emquest_rank:rank(<<"anything">>, [tagged(9, <<"whatever">>, 0)], Vec),
    ?assertEqual([9], Sids).
