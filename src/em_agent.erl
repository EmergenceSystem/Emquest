%%%-------------------------------------------------------------------
%%% @doc em_agent — meta-agent behaviour and phase registry.
%%%
%%% A meta-agent is a module implementing this behaviour:
%%%
%%% ```
%%% -callback run(Ctx :: map()) -> {ok, map()} | skip.
%%% '''
%%%
%%% `Ctx' is the query context threaded through the pipeline (e.g.
%%% `#{query, subqueries, peers, ...}'). A meta-agent either augments
%%% it (`{ok, NewCtx}') or declines (`skip').
%%%
%%% Meta-agents are registered per pipeline phase and read from the
%%% `[agents]' section of `emergence.conf': `router = on|off'
%%% enables/disables the `select' phase's `agent_router'. Adding a new
%%% meta-agent later is a new
%%% module plus one clause in `phase_agents/1' plus one config line —
%%% no changes to the pipeline itself.
%%%
%%% `run_phase/2' folds the enabled modules for a phase over `Ctx'.
%%% Each `run/1' call is wrapped in try/catch: a `skip', an
%%% exception, or a crash all leave `Ctx' unchanged, so a broken or
%%% disabled meta-agent can never make a query worse than today's
%%% behaviour — callers are expected to fall back to the current
%%% (pre-meta-agent) logic when the phase key they were expecting is
%%% absent from the returned `Ctx'.
%%% @end
%%%-------------------------------------------------------------------
-module(em_agent).
-include_lib("kernel/include/logger.hrl").

-callback run(Ctx :: map()) -> {ok, map()} | skip.

-export([run_phase/2, doc_text/1]).

%%--------------------------------------------------------------------
%% @doc Fold the enabled meta-agents for `Phase' over `Ctx'.
%%
%% Registered phases: `select' (`agent_router', gated by
%% `[agents] router'), `rerank' (`agent_dedup' + `agent_judge', gated
%% by `[agents] dedup'/`judge'). Unwired phases and disabled agents
%% simply return `Ctx' unchanged.
%% @end
%%--------------------------------------------------------------------
-spec run_phase(atom(), map()) -> map().
run_phase(Phase, Ctx) ->
    lists:foldl(fun(Mod, Acc) -> run_one(Mod, Phase, Acc) end,
                Ctx, phase_agents(Phase)).

%% @doc Title + resume text for a raw agent result item, used as the
%% document side fed to the embedder (`agent_dedup') and the
%% cross-encoder (`agent_judge'). Shared here so both meta-agents use
%% the exact same extraction.
-spec doc_text(map()) -> binary().
doc_text(Item) ->
    Props = maps:get(<<"properties">>, Item, Item),
    L = to_bin(maps:get(<<"title">>,  Props, maps:get(<<"label">>, Props, <<>>))),
    V = to_bin(maps:get(<<"resume">>, Props, maps:get(<<"value">>, Props, <<>>))),
    case V of <<>> -> L; _ -> <<L/binary, " ", V/binary>> end.

%% @private
to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<>>.

%%====================================================================
%% Internal
%%====================================================================

%% @private
run_one(Mod, Phase, Ctx) ->
    try Mod:run(Ctx) of
        {ok, NewCtx} when is_map(NewCtx) -> NewCtx;
        skip                             -> Ctx;
        Other ->
            ?LOG_WARNING("[em_agent] ~p:run/1 (~p phase) returned ~p, "
                         "ignoring", [Mod, Phase, Other]),
            Ctx
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING("[em_agent] ~p:run/1 crashed (~p phase): ~p:~p~n~p",
                         [Mod, Phase, Class, Reason, Stack]),
            Ctx
    end.

%% @private
%% @doc Enabled agent modules for `Phase', in fold order.
phase_agents(select) ->
    case agent_on("router") of
        true  -> [agent_router];
        false -> []
    end;
phase_agents(rerank) ->
    lists:append([
        case agent_on("dedup") of true  -> [agent_dedup]; false -> [] end,
        case agent_on("judge") of true  -> [agent_judge]; false -> [] end
    ]);
phase_agents(_Phase) ->
    [].

%% @private
%% @doc `[agents] Name = on|off' — defaults to `on' when unset so a
%% missing config section doesn't silently disable everything.
agent_on(Name) ->
    emconf:get_bool("agents", Name, true).
