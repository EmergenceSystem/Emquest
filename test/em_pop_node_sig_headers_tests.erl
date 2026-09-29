-module(em_pop_node_sig_headers_tests).
-include_lib("eunit/include/eunit.hrl").

-define(PT, {em_pop_crypto, keypair}).

with_key(Fun) ->
    Old = persistent_term:get(?PT, undefined),
    try Fun()
    after
        case Old of
            undefined -> catch persistent_term:erase(?PT);
            _         -> persistent_term:put(?PT, Old)
        end
    end.

sig_headers_signs_when_key_loaded_test() ->
    with_key(fun() ->
        {Pub, Priv} = em_pop_crypto:keypair(),
        persistent_term:put(?PT, {Pub, Priv}),
        Body = <<"{\"x\":1}">>,
        H = em_pop_node:sig_headers(Body),
        Id = em_pop_crypto:id_of(Pub),
        ?assertEqual(binary_to_list(base64:encode(Id)), proplists:get_value("x-pop-id", H)),
        Ts = list_to_integer(proplists:get_value("x-pop-ts", H)),
        Sig = base64:decode(list_to_binary(proplists:get_value("x-pop-sig", H))),
        ?assert(em_pop_crypto:verify(
                  em_pop_crypto:canonical_gossip_auth(Id, Ts, crypto:hash(sha256, Body)),
                  Sig, Pub))
    end).

sig_headers_empty_when_no_key_test() ->
    with_key(fun() ->
        catch persistent_term:erase(?PT),
        ?assertEqual([], em_pop_node:sig_headers(<<"{}">>))
    end).
