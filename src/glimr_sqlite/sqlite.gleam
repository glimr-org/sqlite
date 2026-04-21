//// SQLite Adapter
////
//// The SQLite counterpart to glimr_postgres/postgres.gleam.
//// Same idea — a clean public entry point that hides config
//// parsing and pool construction behind simple start calls.
//// SQLite is particularly appealing for smaller apps and local
//// development since there's no separate server to manage, but
//// it still goes through the same Pool abstraction so
//// switching to Postgres later doesn't require changing
//// application code.
////

import gleam/string
import glimr/cache.{type CachePool}
import glimr/db/db.{type DbPool}
import glimr/db/driver
import glimr/session.{type SessionStore}
import glimr_sqlite/db/pool
import glimr_sqlite/db/query
import glimr_sqlite/session/session_store

// ------------------------------------------------------------- Public Functions

/// The one-liner every app's main module calls at boot. Loads
/// database.toml, finds the named connection, and starts a pool
/// — no config parsing or driver types to deal with. The assert
/// crash is intentional: a broken database path at startup is
/// unrecoverable, and crashing immediately gives a clear stack
/// trace instead of propagating errors through every downstream
/// function that tries to use the pool.
///
pub fn start(name: String) -> DbPool {
  let connections = driver.load_connections()
  let conn = driver.find_by_name(name, connections)
  let config = driver.to_config(conn)
  start_from_config(config)
}

/// SQLite is already a single file — using the same file for
/// caching means zero extra infrastructure. This wires your
/// existing database pool into the framework's cache system
/// using a regular SQL table, same CachePool API as the Redis
/// and file backends.
///
pub fn start_cache(db_pool: DbPool, name: String) -> CachePool {
  cache.database_start(db_pool, name)
}

/// For apps already using SQLite, storing sessions in the same
/// database keeps things simple — no Redis or extra
/// infrastructure. Pass the result to `session.setup()` in your
/// bootstrap and sessions live right alongside your application
/// data.
///
pub fn session_store(pool: DbPool) -> SessionStore {
  session_store.create(pool)
}

// ------------------------------------------------------------- Internal Public Functions

/// Console commands like `db:migrate` need to start a pool but
/// shouldn't crash on failure — they should print a helpful
/// error message instead. This is the non-panicking variant of
/// start_from_config that returns a Result so the command can
/// handle the error gracefully.
///
@internal
pub fn try_start_from_config(config: db.Config) -> Result(DbPool, String) {
  case pool.start_pool(config) {
    Ok(db_pool) -> Ok(wrap_pool(db_pool))
    Error(e) -> Error(string.inspect(e))
  }
}

/// Tests need pools without reading database.toml — they supply
/// in-memory databases (`:memory:`) or temp-file paths
/// directly. Accepting a pre-built Config skips the file I/O
/// and config lookup entirely.
///
@internal
pub fn start_from_config(config: db.Config) -> DbPool {
  let assert Ok(db_pool) = pool.start_pool(config)
  wrap_pool(db_pool)
}

/// The rest of the framework talks to databases through a
/// generic DbPool — it doesn't know or care whether it's SQLite
/// or Postgres underneath. This is where we plug sqlight's
/// query and exec functions into that generic interface, so
/// `db.query` on a SQLite pool routes to the right driver
/// without any caller needing to know.
///
@internal
pub fn wrap_pool(db_pool: pool.Pool) -> DbPool {
  let #(checkout, stop) = pool.raw_checkout(db_pool)

  db.new_pool(
    driver: db.Sqlite,
    query_fn: db.to_dynamic(query.vtable_query),
    exec_fn: db.to_dynamic(query.vtable_exec),
    checkout: fn() {
      case checkout() {
        Ok(#(conn, release)) -> Ok(#(db.to_dynamic(conn), release))
        Error(msg) -> Error(msg)
      }
    },
    stop: stop,
  )
}
