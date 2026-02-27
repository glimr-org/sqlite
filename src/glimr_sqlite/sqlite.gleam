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
import glimr/cache/cache.{type CachePool}
import glimr/cache/database as cache_database
import glimr/config/database
import glimr/db/driver
import glimr/db/pool_connection.{type DbPool}
import glimr/session/session.{type Session}
import glimr/session/store
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
  let connections = database.load()
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
  cache_database.start(db_pool, name)
}

/// Registers the SQLite session store in persistent_term so the
/// session middleware can load, save, and destroy sessions
/// without knowing which backend is active. This must be called
/// at boot before any requests arrive — once registered, the
/// store is available to every BEAM process without being
/// threaded through function arguments.
///
pub fn start_session(pool: DbPool) -> Session {
  let session = session_store.create(pool)
  store.cache_store(session)

  session.empty()
}

// ------------------------------------------------------------- Internal Public Functions

/// Console commands like `db:migrate` need to start a pool but
/// shouldn't crash on failure — they should print a helpful
/// error message instead. This is the non-panicking variant of
/// start_from_config that returns a Result so the command can
/// handle the error gracefully.
///
@internal
pub fn try_start_from_config(
  config: pool_connection.Config,
) -> Result(DbPool, String) {
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
pub fn start_from_config(config: pool_connection.Config) -> DbPool {
  let assert Ok(db_pool) = pool.start_pool(config)
  wrap_pool(db_pool)
}

/// The framework's Pool type uses dynamic-typed vtable
/// callbacks so it can work with any database driver without
/// knowing the concrete types. This wires in the
/// SQLite-specific query and exec implementations so code that
/// receives a Pool can call pool_connection.query or
/// pool_connection.exec and have it route to sqlight under the
/// hood.
///
@internal
pub fn wrap_pool(db_pool: pool.Pool) -> DbPool {
  let #(checkout, stop) = pool.raw_checkout(db_pool)

  pool_connection.new_pool(
    driver: pool_connection.Sqlite,
    query_fn: pool_connection.to_dynamic(query.vtable_query),
    exec_fn: pool_connection.to_dynamic(query.vtable_exec),
    checkout: fn() {
      case checkout() {
        Ok(#(conn, release)) -> Ok(#(pool_connection.to_dynamic(conn), release))
        Error(msg) -> Error(msg)
      }
    },
    stop: stop,
  )
}
