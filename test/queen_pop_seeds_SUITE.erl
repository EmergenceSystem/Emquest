-module(queen_pop_seeds_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0]).
-export([pop_seeds_empty_without_pop_port/1,
         pop_seeds_parses_host_and_port/1,
         emquest_pop_port_defaults_to_9100/1]).

all() ->
    [pop_seeds_empty_without_pop_port,
     pop_seeds_parses_host_and_port,
     emquest_pop_port_defaults_to_9100].

%% When no conf file is found (or pop_port absent), pop_seeds returns [].
pop_seeds_empty_without_pop_port(_Config) ->
    %% Run in a temp dir with no conf so read_conf returns undefined.
    OldHome = os:getenv("HOME"),
    TmpDir  = filename:join(os:getenv("TEMP", "/tmp"),
                             "queen_test_empty_" ++
                             integer_to_list(erlang:unique_integer([positive]))),
    ok      = filelib:ensure_dir(filename:join(TmpDir, "x")),
    os:putenv("HOME", TmpDir),
    try
        [] = queen:pop_seeds()
    after
        case OldHome of
            false -> os:unsetenv("HOME");
            H     -> os:putenv("HOME", H)
        end,
        file:del_dir_r(TmpDir)
    end.

%% pop_seeds parses nodes + pop_port correctly.
pop_seeds_parses_host_and_port(Config) ->
    PrivDir = ?config(priv_dir, Config),
    OldHome = os:getenv("HOME"),
    os:putenv("HOME", PrivDir),
    %% Resolve the conf path as queen would see it, then create the file there.
    ConfFile = queen:conf_path(),
    ok       = filelib:ensure_dir(ConfFile),
    ok       = file:write_file(
                  ConfFile,
                  "[em_disco]\nnodes = seed.example.com:8080\npop_port = 9000\n"),
    try
        Seeds = queen:pop_seeds(),
        true  = lists:member({"seed.example.com", 9000}, Seeds)
    after
        case OldHome of
            false -> os:unsetenv("HOME");
            H     -> os:putenv("HOME", H)
        end
    end.

%% emquest_pop_port/0 returns 9100 when [emquest] pop_port is absent.
emquest_pop_port_defaults_to_9100(_Config) ->
    OldHome = os:getenv("HOME"),
    TmpDir  = filename:join(os:getenv("TEMP", "/tmp"),
                             "queen_test_port_" ++
                             integer_to_list(erlang:unique_integer([positive]))),
    ok      = filelib:ensure_dir(filename:join(TmpDir, "x")),
    os:putenv("HOME", TmpDir),
    try
        9100 = queen:emquest_pop_port()
    after
        case OldHome of
            false -> os:unsetenv("HOME");
            H     -> os:putenv("HOME", H)
        end,
        file:del_dir_r(TmpDir)
    end.
