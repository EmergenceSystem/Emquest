%%%-------------------------------------------------------------------
%%% @doc em_vec — shared vector math for routing/ranking/dedup.
%%%
%%% One home for the cosine/dot helpers that agent_router, agent_dedup
%%% and emquest_rank each used to carry their own copy of. All
%%% functions degrade gracefully (return 0.0) rather than raising, so
%%% the routing/ranking paths never crash on a malformed vector.
%%% @end
%%%-------------------------------------------------------------------
-module(em_vec).

-export([cosine/2, dot/2, dot_f32/2]).

%%--------------------------------------------------------------------
%% @doc Cosine similarity of two equal-length float lists. Returns
%% `0.0' on a dimension mismatch or a zero-norm vector rather than
%% raising.
%% @end
%%--------------------------------------------------------------------
-spec cosine([float()], [float()]) -> float().
cosine(A, B) when is_list(A), is_list(B), length(A) =:= length(B) ->
    Dot = dot(A, B),
    NA  = math:sqrt(dot(A, A)),
    NB  = math:sqrt(dot(B, B)),
    Denom = NA * NB,
    if
        Denom < 1.0e-12, Denom > -1.0e-12 -> 0.0;
        true                              -> Dot / Denom
    end;
cosine(_, _) ->
    0.0.

%%--------------------------------------------------------------------
%% @doc Dot product of two float lists (walks the shorter length).
%% @end
%%--------------------------------------------------------------------
-spec dot([float()], [float()]) -> float().
dot(A, B) -> dot(A, B, 0.0).

dot([X | Xs], [Y | Ys], Acc) -> dot(Xs, Ys, Acc + X * Y);
dot(_, _, Acc) -> Acc.

%%--------------------------------------------------------------------
%% @doc Dot product of two f32 little-endian unit-vector binaries
%% (= cosine, since both are L2-normalised by `em_filter_vec').
%% @end
%%--------------------------------------------------------------------
-spec dot_f32(binary(), binary()) -> float().
dot_f32(A, B) ->
    FA = [F || <<F:32/float-little>> <= A],
    FB = [F || <<F:32/float-little>> <= B],
    dot(FA, FB).
