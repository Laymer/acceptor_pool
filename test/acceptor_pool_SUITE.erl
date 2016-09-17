-module(acceptor_pool_SUITE).

-include_lib("common_test/include/ct.hrl").

-define(TIMEOUT, 5000).

%% common_test api

-export([all/0,
         groups/0,
         suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

%% test cases

-export([accept/1,
         close_socket/1,
         which_sockets/1,
         which_children/1,
         count_children/1,
         format_status/1,
         start_error/1,
         child_error/1,
         permanent_shutdown/1,
         transient_shutdown/1,
         shutdown_children/1,
         kill_children/1]).

%% common_test api

all() ->
    [{group, tcp},
     {group, supervisor},
     {group, permanent},
     {group, transient},
     {group, temporary},
     {group, shutdown_timeout},
     {group, brutal_kill}].

groups() ->
    [{tcp, [parallel], [accept, close_socket, which_sockets]},
     {supervisor, [parallel], [which_children, count_children, format_status]},
     {permanent, [start_error, child_error, permanent_shutdown]},
     {transient, [start_error, child_error, transient_shutdown]},
     {temporary, [start_error]},
     {shutdown_timeout, [shutdown_children, kill_children]},
     {brutal_kill, [shutdown_children, kill_children]}].

suite() ->
    [{timetrap, {seconds, 15}}].

init_per_suite(Config) ->
    {ok, Started} = application:ensure_all_started(acceptor_pool),
    [{started, Started} | Config].

end_per_suite(Config) ->
    Started = ?config(started, Config),
    _ = [application:stop(App) || App <- Started],
    ok.

init_per_group(permanent, Config) ->
    [{restart, permanent} | init_per_group(all, Config)];
init_per_group(transient, Config) ->
    [{restart, transient} | init_per_group(all, Config)];
init_per_group(brutal_kill, Config) ->
    [{shutdown, brutal_kill} | init_per_group(all, Config)];
init_per_group(_, Config) ->
    [{restart, temporary} || undefined == ?config(restart, Config)] ++
    [{shutdown, 500} || undefined == ?config(shutdown, Config)] ++
    Config.

end_per_group(_, _) ->
    ok.

init_per_testcase(start_error, Config) ->
    Config;
init_per_testcase(kill_children, Config) ->
    init_per_testcase(all, [{init, {ok, trap_exit}} | Config]);
init_per_testcase(_TestCase, Config) ->
    Opts = [{active, false}, {packet, 4}],
    {ok, LSock} = gen_tcp:listen(0, Opts),
    {ok, Port} = inet:port(LSock),
    Init = proplists:get_value(init, Config, {ok, undefined}),
    Spec = #{id => acceptor_pool_test,
             start => {acceptor_pool_test, Init, []},
             restart => ?config(restart, Config),
             shutdown => ?config(shutdown, Config)},
    {ok, Pool} = acceptor_pool_test:start_link(Spec),
    {ok, Ref} = acceptor_pool:accept_socket(Pool, LSock, 1),
    Connect = fun() -> gen_tcp:connect("localhost", Port, Opts, ?TIMEOUT) end,
    [{connect, Connect}, {pool, Pool}, {ref, Ref}, {socket, LSock} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

%% test cases

accept(Config) ->
    Connect = ?config(connect, Config),

    {ok, ClientA} = Connect(),
    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),
    ok = gen_tcp:close(ClientA),

    {ok, ClientB} = Connect(),
    ok = gen_tcp:send(ClientB, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientB, 0, ?TIMEOUT),
    ok = gen_tcp:close(ClientB),

    {ok, ClientC} = Connect(),
    ok = gen_tcp:send(ClientC, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientC, 0, ?TIMEOUT),
    ok = gen_tcp:close(ClientC),

    ok.

close_socket(Config) ->
    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    LSock = ?config(socket, Config),
    ok = gen_tcp:close(LSock),

    {error, _} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),
    ok = gen_tcp:close(ClientA),

    ok.

which_sockets(Config) ->
    LSock = ?config(socket, Config),
    {ok, Port} = inet:port(LSock),
    Ref = ?config(ref, Config),
    Pool = ?config(pool, Config),

    [{inet_tcp, {_, Port}, LSock, Ref}] = acceptor_pool:which_sockets(Pool),

    ok.

which_children(Config) ->
    Pool = ?config(pool, Config),

    [] = acceptor_pool:which_children(Pool),

    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    [{{acceptor_pool_test, {_, _}, {_,_}, _}, Pid, worker,
      [acceptor_pool_test]}] = acceptor_pool:which_children(Pool),

    Ref = monitor(process, Pid),

    ok = gen_tcp:close(ClientA),

    receive {'DOWN', Ref, _, _, _} -> ok end,

    [] = acceptor_pool:which_children(Pool),

    ok.

count_children(Config) ->
    Pool = ?config(pool, Config),

    % workers is 1 because 1 acceptor
    [{specs, 1}, {active, 0}, {supervisors, 0}, {workers, 1}] =
        acceptor_pool:count_children(Pool),

    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    % workers is 2 because 1 active connection and 1 acceptor
    [{specs, 1}, {active, 1}, {supervisors, 0}, {workers, 2}] =
        acceptor_pool:count_children(Pool),

    [{_, Pid, _, _}] = acceptor_pool:which_children(Pool),

    Ref = monitor(process, Pid),

    ok = gen_tcp:close(ClientA),

    receive {'DOWN', Ref, _, _, _} -> ok end,

    % workers is 1 because 1 acceptor
    [{specs, 1}, {active, 0}, {supervisors, 0}, {workers, 1}] =
        acceptor_pool:count_children(Pool),

    ok.

format_status(Config) ->
    Pool = ?config(pool, Config),

    {status, Pool, {module, _}, Items} = sys:get_status(Pool),

    [_PDict, running, _Parent, [], Misc] = Items,

    {supervisor, [{"Callback", acceptor_pool_test}]} =
        lists:keyfind(supervisor, 1, Misc),

    ok.

start_error(Config) ->
    _ = process_flag(trap_exit, true),
    Spec = #{id => acceptor_pool_test,
             start => {acceptor_pool_test, {error, shutdown}, []},
             restart => ?config(restart, Config)},
    {ok, Pool} = acceptor_pool_test:start_link(Spec),

    {ok, LSock} = gen_tcp:listen(0, []),
    {ok, _} = acceptor_pool:accept_socket(Pool, LSock, 1),

    receive {'EXIT', Pool, shutdown} -> ok end,

    ok.

child_error(Config) ->
    _ = process_flag(trap_exit, true),
    Pool = ?config(pool, Config),
    Connect = ?config(connect, Config),

    {ok, ClientA} = Connect(),
    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    {ok, ClientB} = Connect(),
    ok = gen_tcp:send(ClientB, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientB, 0, ?TIMEOUT),

    [{_, Pid1, _, _}, {_, Pid2, _, _}] = acceptor_pool:which_children(Pool),

    exit(Pid1, oops),
    exit(Pid2, oops),

    receive {'EXIT', Pool, shutdown} -> ok end,

    ok.

permanent_shutdown(Config) ->
    _ = process_flag(trap_exit, true),
    Pool = ?config(pool, Config),
    Connect = ?config(connect, Config),

    {ok, ClientA} = Connect(),
    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    {ok, ClientB} = Connect(),
    ok = gen_tcp:send(ClientB, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientB, 0, ?TIMEOUT),

    [{_, Pid1, _, _}, {_, Pid2, _, _}] = acceptor_pool:which_children(Pool),

    exit(Pid1, shutdown),
    exit(Pid2, {shutdown, oops}),

    receive {'EXIT', Pool, shutdown} -> ok end,

    ok.

transient_shutdown(Config) ->
    Pool = ?config(pool, Config),
    Connect = ?config(connect, Config),

    {ok, ClientA} = Connect(),
    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    {ok, ClientB} = Connect(),
    ok = gen_tcp:send(ClientB, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientB, 0, ?TIMEOUT),

    [{_, Pid1, _, _}, {_, Pid2, _, _}] = acceptor_pool:which_children(Pool),

    exit(Pid1, shutdown),
    exit(Pid2, {shutdown, oops}),

    {ok, ClientC} = Connect(),
    ok = gen_tcp:send(ClientC, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientC, 0, ?TIMEOUT),

    ok.

shutdown_children(Config) ->
    Connect = ?config(connect, Config),

    {ok, ClientA} = Connect(),
    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    {ok, ClientB} = Connect(),
    ok = gen_tcp:send(ClientB, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientB, 0, ?TIMEOUT),

    Pool = ?config(pool, Config),
    [{_, Pid1, _, _}, {_, Pid2, _, _}] = acceptor_pool:which_children(Pool),

    {links, Links} = process_info(Pool, links),
    [Acceptor] = Links -- [Pid1, Pid2, self()],

    Ref1 = monitor(process, Pid1),
    Ref2 = monitor(process, Pid2),
    ARef = monitor(process, Acceptor),

    _ = process_flag(trap_exit, true),
    exit(Pool, shutdown),

    Reason = case ?config(shutdown, Config) of
                 brutal_kill -> killed;
                 _           -> shutdown
             end,

    receive {'DOWN', Ref1, _, _, Reason} -> ok end,
    receive {'DOWN', Ref2, _, _, Reason} -> ok end,
    receive {'DOWN', ARef, _, _, Reason} -> ok end,

    receive {'EXIT', Pool, shutdown} -> ok end,

    ok.

kill_children(Config) ->
    Connect = ?config(connect, Config),

    {ok, ClientA} = Connect(),
    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    {ok, ClientB} = Connect(),
    ok = gen_tcp:send(ClientB, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientB, 0, ?TIMEOUT),

    Pool = ?config(pool, Config),
    [{_, Pid1, _, _}, {_, Pid2, _, _}] = acceptor_pool:which_children(Pool),

    {links, Links} = process_info(Pool, links),
    [Acceptor] = Links -- [Pid1, Pid2, self()],

    Ref1 = monitor(process, Pid1),
    Ref2 = monitor(process, Pid2),
    ARef = monitor(process, Acceptor),

    _ = process_flag(trap_exit, true),
    exit(Pool, shutdown),

    Shutdown = ?config(shutdown, Config),
    receive
        {'DOWN', ARef, _, _, shutdown} when Shutdown /= brutal_kill -> ok;
        {'DOWN', ARef, _, _, killed} when Shutdown == brutal_kill -> ok
    end,
    receive {'DOWN', Ref1, _, _, killed} -> ok end,
    receive {'DOWN', Ref2, _, _, killed} -> ok end,

    receive {'EXIT', Pool, shutdown} -> ok end,

    ok.
