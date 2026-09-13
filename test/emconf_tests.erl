-module(emconf_tests).
-include_lib("eunit/include/eunit.hrl").

%% Point HOME at a temp dir carrying a crafted emergence.conf, so the
%% getters read known values. HOME is restored (and the cache flushed)
%% in teardown so other test modules see the real environment.
setup() ->
    Old = os:getenv("HOME"),
    Tmp = filename:join("/tmp", "emconf_test_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    Dir = filename:join([Tmp, ".config", "emergence"]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Conf =
        "[agents]\n"
        "router = off\n"
        "judge_top_n = 5\n"
        "dedup_threshold = 0.8\n"
        "\n"
        "[rank]\n"
        "wL = 0.7\n"
        "mmr = off\n",
    ok = file:write_file(filename:join(Dir, "emergence.conf"), Conf),
    os:putenv("HOME", Tmp),
    emconf:flush(),
    {Old, Tmp}.

teardown({Old, Tmp}) ->
    case Old of
        false -> os:unsetenv("HOME");
        _     -> os:putenv("HOME", Old)
    end,
    emconf:flush(),
    _ = file:del_dir_r(Tmp),
    ok.

emconf_test_() ->
    {setup, fun setup/0, fun teardown/1,
     fun(_) ->
        [ ?_assertEqual(false, emconf:get_bool("agents", "router", true)),
          ?_assertEqual(true,  emconf:get_bool("agents", "missing", true)),
          ?_assertEqual(false, emconf:get_bool("rank", "mmr", true)),
          ?_assertEqual(true,  emconf:get_bool("rank", "progressive", true)),
          ?_assertEqual(5,     emconf:get_int("agents", "judge_top_n", 20)),
          ?_assertEqual(20,    emconf:get_int("agents", "missing", 20)),
          ?_assertEqual(20,    emconf:get_int("missing_section", "k", 20)),
          ?_assert(abs(emconf:get_float("agents", "dedup_threshold", 0.9) - 0.8) < 1.0e-9),
          ?_assert(abs(emconf:get_float("rank", "wL", 0.6) - 0.7) < 1.0e-9),
          ?_assert(abs(emconf:get_float("rank", "missing", 0.25) - 0.25) < 1.0e-9),
          ?_assertEqual("off", emconf:get_string("agents", "router", "on")),
          ?_assertEqual("dflt2", emconf:get_string("agents", "missing", "dflt2")),
          ?_assertEqual(#{"router" => "off", "judge_top_n" => "5",
                          "dedup_threshold" => "0.8"},
                        emconf:section("agents")) ]
     end}.
