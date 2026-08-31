-module(emquest_rank_tests).
-include_lib("eunit/include/eunit.hrl").

item(Title, Resume) ->
    #{<<"properties">> => #{<<"title">> => Title, <<"resume">> => Resume,
                            <<"url">> => <<"http://x">>}}.

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
