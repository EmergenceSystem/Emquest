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
%%% `[agents]' section of `emergence.conf' (mirroring how `queen'
%%% reads `[llm]'): `router = on|off' enables/disables the `select'
%%% phase's `agent_router'. Adding a new meta-agent later is a new
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

-export([run_phase/2, conf/0]).

%%--------------------------------------------------------------------
%% @doc Fold the enabled meta-agents for `Phase' over `Ctx'.
%%
%% For LOT 1, only the `select' phase has a registered agent
%% (`agent_router', gated by `[agents] router'). Unwired phases and
%% disabled agents simply return `Ctx' unchanged.
%% @end
%%--------------------------------------------------------------------
-spec run_phase(atom(), map()) -> map().
run_phase(Phase, Ctx) ->
    lists:foldl(fun(Mod, Acc) -> run_one(Mod, Phase, Acc) end,
                Ctx, phase_agents(Phase)).

%% @doc Return the raw `[agents]' section of `emergence.conf' as a
%% `#{string() => string()}' map (same shape `queen:parse_conf/1'
%% produces per-section) — used by meta-agents that need their own
%% tunables (e.g. `agent_router' reading `router_k').
-spec conf() -> #{string() => string()}.
conf() ->
    case queen:conf_path() of
        undefined -> #{};
        Path ->
            case file:read_file(Path) of
                {ok, Bin} -> maps:get("agents", queen:parse_conf(Bin), #{});
                _         -> #{}
            end
    end.

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
phase_agents(_Phase) ->
    [].

%% @private
%% @doc `[agents] Name = on|off' — defaults to `on' when unset so a
%% missing config section doesn't silently disable everything.
agent_on(Name) ->
    case maps:get(Name, conf(), "on") of
        "off" -> false;
        _     -> true
    end.
