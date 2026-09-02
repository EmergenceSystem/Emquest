%%%-------------------------------------------------------------------
%%% @doc SSRF guard for outbound fetches driven by peer/user data.
%%%
%%% A URL is safe only when its scheme is http/https AND every address
%%% its host resolves to is a public unicast address. Private, loopback,
%%% link-local (incl. cloud metadata 169.254.169.254) and unique-local
%%% ranges are refused. Use `safe_get/3' in place of `httpc:request/4'
%%% for any URL that originates from an untrusted peer or end user.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_safeurl).
-export([check/1, check_scheme/1, is_blocked_ip/1, safe_get/3]).

-define(ALLOWED_SCHEMES, [<<"http">>, <<"https">>]).

%% @doc Full pre-flight: scheme allow-list + resolve host + block private IPs.
-spec check(binary()) -> ok | {error, term()}.
check(Url) when is_binary(Url) ->
    case check_scheme(Url) of
        ok ->
            case host_of(Url) of
                {ok, Host} -> check_host_addrs(Host);
                Err        -> Err
            end;
        Err -> Err
    end.

-spec check_scheme(binary()) -> ok | {error, bad_scheme}.
check_scheme(Url) ->
    case uri_string:parse(Url) of
        #{scheme := S} ->
            case lists:member(string:lowercase(S), ?ALLOWED_SCHEMES) of
                true  -> ok;
                false -> {error, bad_scheme}
            end;
        _ -> {error, bad_scheme}
    end.

host_of(Url) ->
    case uri_string:parse(Url) of
        #{host := H} when H =/= <<>> -> {ok, H};
        _ -> {error, no_host}
    end.

check_host_addrs(Host) ->
    HostStr = binary_to_list(Host),
    A4 = case inet:getaddrs(HostStr, inet)  of {ok, L4} -> L4; _ -> [] end,
    A6 = case inet:getaddrs(HostStr, inet6) of {ok, L6} -> L6; _ -> [] end,
    case A4 ++ A6 of
        []    -> {error, unresolvable};
        Addrs ->
            case lists:any(fun is_blocked_ip/1, Addrs) of
                true  -> {error, blocked_ip};
                false -> ok
            end
    end.

%% @doc True for loopback / private / link-local / unique-local addresses.
%% IPv4
-spec is_blocked_ip(inet:ip_address()) -> boolean().
is_blocked_ip({0,_,_,_})       -> true;           %% 0.0.0.0/8
is_blocked_ip({127,_,_,_})     -> true;
is_blocked_ip({10,_,_,_})      -> true;
is_blocked_ip({192,168,_,_})   -> true;
is_blocked_ip({169,254,_,_})   -> true;
is_blocked_ip({172,B,_,_}) when B >= 16, B =< 31 -> true;
is_blocked_ip({100,B,_,_}) when B >= 64, B =< 127 -> true;  %% CGNAT 100.64/10
is_blocked_ip({_,_,_,_})       -> false;
%% IPv6 embedded-IPv4 (mapped ::ffff:0:0/96, compat ::/96, NAT64 64:ff9b::/96)
is_blocked_ip({0,0,0,0,0,16#ffff,G,H}) -> is_blocked_ip(v4_of(G,H));
is_blocked_ip({16#64,16#ff9b,0,0,0,0,G,H}) -> is_blocked_ip(v4_of(G,H));
is_blocked_ip({0,0,0,0,0,0,G,H}) when (G bsl 16) bor H =/= 0,
                                       (G bsl 16) bor H =/= 1 -> is_blocked_ip(v4_of(G,H));
%% IPv6 native
is_blocked_ip({0,0,0,0,0,0,0,1}) -> true;
is_blocked_ip({W,_,_,_,_,_,_,_}) when W >= 16#fe80, W =< 16#febf -> true;
is_blocked_ip({W,_,_,_,_,_,_,_}) when W >= 16#fc00, W =< 16#fdff -> true;
is_blocked_ip({_,_,_,_,_,_,_,_}) -> false.

%% @private embedded IPv4 from the low 32 bits of a mapped/compat/NAT64 address.
v4_of(G, H) -> {G bsr 8, G band 16#ff, H bsr 8, H band 16#ff}.

%% @doc SSRF-checked GET. Same shape as the httpc calls it replaces.
-spec safe_get(binary(), [{string(), string()}], [term()]) ->
    {ok, binary()} | {error, term()}.
safe_get(Url, Headers, HttpOpts) ->
    case check(Url) of
        ok ->
            case httpc:request(get, {binary_to_list(Url), Headers},
                               HttpOpts, [{body_format, binary}, {autoredirect, false}]) of
                {ok, {{_, 200, _}, _, Bytes}} -> {ok, Bytes};
                {ok, {{_, C,   _}, _, _}}     -> {error, {http, C}};
                {error, R}                    -> {error, R}
            end;
        Err -> Err
    end.
