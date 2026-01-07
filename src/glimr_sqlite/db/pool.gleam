//// SQLite connection pool management.
////
//// Provides connection pooling for SQLite databases. Pools 
//// manage a set of reusable connections and handle checkout/
//// checkin automatically through the get_connection function.

import gleam/erlang/process
import glimr/db/pool_connection.{
  type Config, ConnectionError, PostgresConfig, PostgresParamsConfig,
  SqliteConfig,
}
import sqlight

// ------------------------------------------------------------- Public Types

/// A SQLite connection pool. Manages reusable database 
/// connections and handles checkout/checkin automatically. 
/// Created with start_pool and should be stopped with stop_pool 
/// when done.
///
pub opaque type Pool {
  Pool(
    checkout: fn() -> Result(#(sqlight.Connection, fn() -> Nil), String),
    stop: fn() -> Nil,
  )
}

/// Pool operations returned from FFI. Contains closures that
/// capture the internal pool handle, providing checkout and
/// stop functionality without exposing Erlang internals.
///
pub type PoolOps {
  PoolOps(
    checkout: fn() -> Result(#(sqlight.Connection, fn() -> Nil), String),
    stop: fn() -> Nil,
  )
}

/// A SQLite database connection. Obtained through get_connection
/// and should not be stored or used outside the callback. This
/// is an alias for the underlying sqlight.Connection type.
///
pub type Connection =
  sqlight.Connection

/// Represents errors that can occur during pool operations.
/// Re-exported from pool_connection for convenience.
///
pub type DbError =
  pool_connection.DbError

// ------------------------------------------------------------- Public Functions

/// Creates a new connection pool from the given configuration.
/// The pool manages a set of reusable database connections and
/// handles checkout/checkin automatically.
///
pub fn start_pool(config: Config) -> Result(Pool, DbError) {
  case start(config) {
    Ok(ops) -> Ok(Pool(checkout: ops.checkout, stop: ops.stop))
    Error(msg) -> Error(ConnectionError(msg))
  }
}

/// Stops a connection pool and closes all connections. Should
/// be called when the pool is no longer needed to free
/// resources. Any connections still in use will be closed.
///
pub fn stop_pool(pool: Pool) -> Nil {
  pool.stop()
}

/// Executes a function with a connection from the pool. The
/// connection is automatically checked out before the function
/// runs and returned to the pool when it completes.
///
pub fn get_connection(pool: Pool, f: fn(Connection) -> a) -> a {
  case pool.checkout() {
    Ok(#(conn, release)) -> {
      let result = f(conn)
      release()
      result
    }
    Error(msg) -> panic as { "Failed to checkout connection: " <> msg }
  }
}

// ------------------------------------------------------------- Internal Functions

/// Starts a SQLite connection pool from the given configuration.
/// Only accepts SqliteConfig, returns an error for Postgres
/// configurations. Returns PoolOps with closures on success.
///
fn start(config: Config) -> Result(PoolOps, String) {
  case config {
    SqliteConfig(path, pool_size) -> {
      let pool_name = process.new_name(prefix: "glimr_sqlite_pool")
      ffi_start_pool(pool_name, path, pool_size)
    }
    PostgresConfig(_, _) -> Error("SQLite driver cannot start Postgres config")
    PostgresParamsConfig(_, _, _, _, _, _) ->
      Error("SQLite driver cannot start Postgres config")
  }
}

// ------------------------------------------------------------- FFI Bindings

/// FFI call to start a pool via Erlang. Returns PoolOps with
/// closures that capture the pool handle internally. The Erlang
/// side manages the actual pool lifecycle and connections.
///
@external(erlang, "sqlite_pool_ffi", "start_pool")
fn ffi_start_pool(
  pool_name: process.Name(a),
  path: String,
  pool_size: Int,
) -> Result(PoolOps, String)
