//// SQLite Command Support
////
//// Console commands that touch the database need a connection
//// pool, but pool lifecycle management (start, use, stop) is
//// boilerplate that every command would repeat. This module
//// wraps that lifecycle so command authors just receive a live
//// pool and focus on their logic. It also validates that the
//// configured connection is actually SQLite before starting
//// the pool, giving a clear error instead of a cryptic driver
//// crash.
////

import gleam/list
import gleam/string
import glimr/cache/driver.{type CacheStore} as _cache_driver
import glimr/console/command.{
  type Args, type Command, CommandWithCache, CommandWithDb,
}
import glimr/console/console
import glimr/db/driver.{SqliteConnection}
import glimr/db/pool_connection.{type Pool}
import glimr_sqlite/db/pool
import glimr_sqlite/db/query

// ------------------------------------------------------------- Public Functions

/// Replaces the command's run function with one that handles
/// the full pool lifecycle automatically. The --database flag
/// is injected so users can select which configured connection
/// to use at runtime. The handler receives a fully typed Pool
/// rather than a generic connection, so command authors get
/// compile-time safety without manual downcasting.
///
pub fn handler(cmd: Command, db_handler: fn(Args, Pool) -> Nil) -> Command {
  let new_args = list.append(cmd.args, [command.db_option()])

  CommandWithDb(
    name: cmd.name,
    description: cmd.description,
    args: new_args,
    driver_type: driver.Sqlite,
    run_with_pool: fn(args, conn) {
      case connection_config(conn) {
        Ok(config) -> with_pool(config, fn(p) { db_handler(args, p) })
        Error(msg) -> print_error(msg)
      }
    },
  )
}

/// Cache-related commands (like cache:clear or cache:table)
/// need both a database pool and the list of configured cache
/// stores so they know which tables to operate on. This variant
/// injects both dependencies, keeping the same pool lifecycle
/// and connection validation as handler while also threading
/// through the cache store configuration.
///
pub fn cache_handler(
  cmd: Command,
  cache_db_handler: fn(Args, Pool, List(CacheStore)) -> Nil,
) -> Command {
  let new_args = list.append(cmd.args, [command.db_option()])

  CommandWithCache(
    name: cmd.name,
    description: cmd.description,
    args: new_args,
    driver_type: driver.Sqlite,
    run_with_cache: fn(args, conn, cache_stores) {
      case connection_config(conn) {
        Ok(config) ->
          with_pool(config, fn(p) { cache_db_handler(args, p, cache_stores) })
        Error(msg) -> print_error(msg)
      }
    },
  )
}

// ------------------------------------------------------------- Private Functions

/// The framework's connection type is a union that covers both
/// PostgreSQL and SQLite variants. This function narrows it to
/// just the SQLite case and extracts the file path and pool size
/// needed to start a pool. Catching missing fields here produces
/// a human-readable error instead of letting the pool driver
/// fail with an opaque crash.
///
fn connection_config(
  conn: driver.Connection,
) -> Result(pool_connection.Config, String) {
  case conn {
    SqliteConnection(_, Ok(path), Ok(pool_size)) ->
      Ok(pool_connection.SqliteConfig(path, pool_size))

    SqliteConnection(_, _, _) ->
      Error("SQLite connection is missing required configuration.")

    _ -> Error("Connection is not SQLite. Use postgres:* commands instead.")
  }
}

/// The pool must be stopped after the callback returns so
/// console commands don't leak connections. Wrapping start
/// and stop around the callback here means command authors
/// can't accidentally forget cleanup, and a failed start
/// prints a useful error instead of panicking.
///
fn with_pool(config: pool_connection.Config, run: fn(Pool) -> Nil) -> Nil {
  case pool.start_pool(config) {
    Ok(p) -> {
      let #(checkout, stop) = pool.raw_checkout(p)
      let core_pool =
        pool_connection.new_pool(
          driver: pool_connection.Sqlite,
          query_fn: pool_connection.to_dynamic(query.vtable_query),
          exec_fn: pool_connection.to_dynamic(query.vtable_exec),
          checkout: fn() {
            case checkout() {
              Ok(#(conn, release)) ->
                Ok(#(pool_connection.to_dynamic(conn), release))
              Error(msg) -> Error(msg)
            }
          },
          stop: stop,
        )
      run(core_pool)
      pool_connection.stop_pool(core_pool)
    }
    Error(e) -> {
      print_error("Failed to start SQLite pool:")
      console.output()
      |> console.line(string.inspect(e))
      |> console.print()
    }
  }
}

/// Centralizes error output so every failure path in this
/// module uses the same styled format. Without this, each
/// call site would repeat the console output boilerplate.
///
fn print_error(msg: String) -> Nil {
  console.output()
  |> console.line_error(msg)
  |> console.print()
}
