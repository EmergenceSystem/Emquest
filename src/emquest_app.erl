-module(emquest_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    io:format("Emquest V0.1.0~n"),
    Port = get_embox_port(),
    
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/", emquest_handler, [index]},
            {"/query", emquest_handler, [query]},
            {"/static/[...]", cowboy_static, {priv_dir, emquest, "static"}}
        ]}
    ]),
    
    {ok, _} = cowboy:start_clear(
        emquest_http,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    
    emquest_sup:start_link().

stop(_State) ->
    ok.

-spec get_embox_port() -> integer().
get_embox_port() ->
    case os:getenv("embox_port") of
        false ->
            ConfigMap = embryo:read_emergence_conf(),
            get_port_from_config(ConfigMap);
        Url -> 
            try list_to_integer(Url)
            catch _:_ -> 8079
            end
    end.

-spec get_port_from_config(map() | undefined) -> integer().
get_port_from_config(undefined) -> 8079;
get_port_from_config(ConfigMap) ->
    case maps:get("embox", ConfigMap, undefined) of
        undefined -> 8079;
        Embox ->
            PortStr = maps:get("port", Embox, "8079"),
            try list_to_integer(PortStr)
            catch _:_ -> 8079
            end
    end.

