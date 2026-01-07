%% FFI for SQLite pool - returns closures that capture the pool handle
-module(sqlite_pool_ffi).

-export([start_pool/3]).

%% Start a pool and return PoolOps with closures
%% PoolOps = {pool_ops, CheckoutFn, StopFn}
%% CheckoutFn = fun() -> {ok, {Conn, ReleaseFn}} | {error, Reason}
%% ReleaseFn = fun() -> nil
%% StopFn = fun() -> nil
start_pool(Name, Path, PoolSize) when is_atom(Name) ->
    Config = #{pool_size => PoolSize},
    case sqlite_pool_sup:start_pool(Name, Path, Config) of
        {ok, PoolName} ->
            CheckoutFn = fun() -> do_checkout(PoolName) end,
            StopFn = fun() -> sqlite_pool_sup:stop_pool(PoolName), nil end,
            {ok, {pool_ops, CheckoutFn, StopFn}};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

%% Internal checkout that returns {ok, {Conn, ReleaseFn}} or {error, Reason}
do_checkout(PoolName) ->
    case sqlite_pool:checkout(PoolName, []) of
        {ok, {PoolRef, Conn}} ->
            ReleaseFn = fun() -> sqlite_pool:checkin(PoolRef, Conn), nil end,
            {ok, {Conn, ReleaseFn}};
        {error, Reason} ->
            {error, format_error(Reason)}
    end.

format_error(Reason) when is_binary(Reason) ->
    Reason;
format_error(Reason) when is_list(Reason) ->
    list_to_binary(Reason);
format_error(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_error({sqlight_error, cantopen, _, _}) ->
    <<"Database file not found or cannot be opened">>;
format_error({sqlight_error, readonly, _, _}) ->
    <<"Database is read-only">>;
format_error({sqlight_error, busy, _, _}) ->
    <<"Database is locked by another process">>;
format_error({sqlight_error, locked, _, _}) ->
    <<"Database table is locked">>;
format_error({sqlight_error, notadb, _, _}) ->
    <<"File is not a valid SQLite database">>;
format_error({sqlight_error, corrupt, _, _}) ->
    <<"Database file is corrupted">>;
format_error({sqlight_error, perm, _, _}) ->
    <<"Permission denied accessing database file">>;
format_error({sqlight_error, ErrorCode, Msg, _}) when is_binary(Msg), byte_size(Msg) > 0 ->
    iolist_to_binary([atom_to_binary(ErrorCode, utf8), <<": ">>, Msg]);
format_error({sqlight_error, ErrorCode, _, _}) ->
    iolist_to_binary([<<"SQLite error: ">>, atom_to_binary(ErrorCode, utf8)]);
format_error({{sqlight_error, _, _, _} = SqlError, _ChildSpec}) ->
    format_error(SqlError);
format_error(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).
