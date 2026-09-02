%%%-------------------------------------------------------------------
%%% @doc ed25519 identity + signing for the em_pop mesh (OTP crypto).
%%%
%%% A peer's id is SHA-256(pubkey)[0:16], binding identity to key so an
%%% id cannot be claimed without the matching private key. `verify_selfsig/1'
%%% checks a peer's enrollment: the signature covers the canonical identity
%%% bytes AND the id must equal id_of(pubkey).
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_crypto).
-export([keypair/0, id_of/1, sign/2, verify/3,
         canonical_identity/1, verify_selfsig/1, canonical_response/1]).

-spec keypair() -> {binary(), binary()}.
keypair() ->
    {Pub, Priv} = crypto:generate_key(eddsa, ed25519),
    {Pub, Priv}.

-spec id_of(binary()) -> binary().
id_of(Pub) -> binary:part(crypto:hash(sha256, Pub), 0, 16).

-spec sign(binary(), binary()) -> binary().
sign(Msg, Priv) -> crypto:sign(eddsa, none, Msg, [Priv, ed25519]).

-spec verify(binary(), binary(), binary()) -> boolean().
verify(Msg, Sig, Pub) ->
    try crypto:verify(eddsa, none, Msg, Sig, [Pub, ed25519])
    catch _:_ -> false end.

-spec canonical_identity(map()) -> binary().
canonical_identity(M) ->
    Id   = to_bin(maps:get(id, M, <<>>)),
    Host = to_bin(maps:get(host, M, <<>>)),
    Port = integer_to_binary(maps:get(port, M, 0)),
    QP   = integer_to_binary(qp(maps:get(query_port, M, 0))),
    Name = to_bin(maps:get(name, M, <<>>)),
    iolist_to_binary([Id, 0, Host, 0, Port, 0, QP, 0, Name]).

-spec verify_selfsig(map()) -> boolean().
verify_selfsig(#{pubkey := Pub, sig := Sig} = M) when is_binary(Pub), is_binary(Sig) ->
    IdOk = maps:get(id, M, undefined) =:= id_of(Pub),
    IdOk andalso verify(canonical_identity(M), Sig, Pub);
verify_selfsig(_) -> false.

qp(undefined) -> 0;
qp(N) when is_integer(N) -> N;
qp(_) -> 0.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> iolist_to_binary(L);
to_bin(_) -> <<>>.

%% @doc Deterministic bytes over a response's item list. Covers the rendered
%% fields (url, title/label, resume/value/description) in list order. Byte-
%% identical to em_filter's em_pop_crypto:canonical_response/1 so signatures verify.
-spec canonical_response(list()) -> binary().
canonical_response(Items) when is_list(Items) ->
    iolist_to_binary([item_line(I) || I <- Items]);
canonical_response(_) -> <<>>.

item_line(I) when is_map(I) ->
    P = case maps:get(<<"properties">>, I, undefined) of
            M when is_map(M) -> M; _ -> I
        end,
    U = pick(P, [<<"url">>]),
    T = pick(P, [<<"title">>, <<"label">>]),
    R = pick(P, [<<"resume">>, <<"value">>, <<"description">>]),
    [U, 0, T, 0, R, 10];
item_line(_) -> [0, 10].

pick(_M, []) -> <<>>;
pick(M, [K|Ks]) ->
    case maps:get(K, M, undefined) of
        V when is_binary(V) -> V;
        _ -> pick(M, Ks)
    end.
