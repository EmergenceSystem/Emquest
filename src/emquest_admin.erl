%%%-------------------------------------------------------------------
%%% @doc Admin authentication for the Emquest admin console.
%%% Per-admin bearer tokens are stored HASHED (sha256 hex) and mapped to a
%%% name so actions are attributable and individually revocable. An optional
%%% IP allowlist is a second factor. Every admin action is appended to an
%%% audit log with the acting admin's name.
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_admin).
-export([authenticate/2, audit/3]).

-spec authenticate(binary() | undefined, binary()) -> {ok, binary()} | {error, term()}.
authenticate(undefined, _Ip) -> {error, no_token};
authenticate(Token, Ip) when is_binary(Token) ->
    Tokens = application:get_env(emquest, admin_tokens, #{}),
    Hash = string:lowercase(binary:encode_hex(crypto:hash(sha256, Token))),
    case maps:get(Hash, Tokens, undefined) of
        undefined -> {error, bad_token};
        Name ->
            case ip_allowed(Ip) of
                true  -> {ok, Name};
                false -> {error, ip_denied}
            end
    end;
authenticate(_, _) -> {error, bad_token}.

ip_allowed(Ip) ->
    case application:get_env(emquest, admin_ips, []) of
        []   -> true;
        Ips  -> lists:member(Ip, Ips)
    end.

-spec audit(binary(), binary(), binary()) -> ok.
audit(AdminName, Action, Target) ->
    catch begin
        F = application:get_env(emquest, admin_audit_log,
                                filename:join(code:priv_dir(emquest), "admin_audit.log")),
        _ = filelib:ensure_dir(F),
        Ts = list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second))),
        Line = <<Ts/binary, "\t", AdminName/binary, "\t", Action/binary, "\t", Target/binary, "\n">>,
        file:write_file(F, Line, [append])
    end,
    ok.
