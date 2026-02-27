//// SQLite Connection Pool
////
//// Opening a new SQLite connection per query adds file I/O
//// overhead and risks hitting OS file descriptor limits
//// under load. A pool keeps a fixed set of connections
//// open and lends them out on demand, so queries execute
//// against already-open handles and callers never need to
//// manage connection lifecycle themselves.

import gleam/erlang/process
import glimr/db/db.{
  type Config, ConnectionError, PostgresConfig, PostgresParamsConfig,
  SqliteConfig,
}
import sqlight

// ------------------------------------------------------------- Public Types

/// The pool must be opaque so callers can't bypass the
/// checkout/checkin protocol by accessing the raw
/// connections directly. Storing closures rather than
/// an Erlang PID keeps the Erlang pool internals hidden
/// from Gleam code.
///
pub opaque type Pool {
  Pool(
    checkout: fn() -> Result(#(sqlight.Connection, fn() -> Nil), String),
    stop: fn() -> Nil,
  )
}

/// The Erlang FFI returns closures that capture the pool
/// handle internally, so a named record type is needed
/// to receive them across the FFI boundary. This stays
/// public so the FFI module can construct it.
///
pub type PoolOps {
  PoolOps(
    checkout: fn() -> Result(#(sqlight.Connection, fn() -> Nil), String),
    stop: fn() -> Nil,
  )
}

/// Re-exporting sqlight.Connection under a local alias
/// lets the rest of the codebase reference Connection
/// without depending on sqlight directly, so swapping
/// the underlying driver only requires changes here.
///
pub type Connection =
  sqlight.Connection

/// Re-exporting DbError here keeps downstream modules
/// from importing db just for the error
/// type, reducing coupling to the framework internals.
///
pub type DbError =
  db.DbError

// ------------------------------------------------------------- Public Functions

/// Wrapping the FFI result in the opaque Pool type ensures
/// callers interact with the pool only through the public
/// API. The Config is validated inside start, so errors
/// from misconfiguration surface here rather than later.
///
pub fn start_pool(config: Config) -> Result(Pool, DbError) {
  case start(config) {
    Ok(ops) -> Ok(Pool(checkout: ops.checkout, stop: ops.stop))
    Error(msg) -> Error(ConnectionError(msg))
  }
}

/// SQLite file locks aren't released until connections
/// close, so stopping the pool explicitly prevents lock
/// contention if another process needs the database
/// file after this application is done with it.
///
pub fn stop_pool(pool: Pool) -> Nil {
  pool.stop()
}

/// A callback-based API guarantees the connection is
/// returned to the pool even if the function crashes,
/// preventing connection leaks that would eventually
/// exhaust the pool under sustained traffic.
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

/// The framework's driver-agnostic Pool vtable needs the
/// raw checkout and stop closures to wire SQLite into
/// the shared db interface. Returning a
/// tuple avoids exposing the opaque Pool internals.
///
pub fn raw_checkout(
  pool: Pool,
) -> #(fn() -> Result(#(sqlight.Connection, fn() -> Nil), String), fn() -> Nil) {
  #(pool.checkout, pool.stop)
}

// ------------------------------------------------------------- Private Functions

/// Config is a shared union across drivers, so a Postgres
/// variant could arrive here by mistake. Matching on the
/// config type and rejecting non-SQLite variants gives a
/// clear error instead of a confusing FFI crash.
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

/// SQLite's C library is accessed through NIF bindings
/// that require Erlang-level process management for
/// connection pooling. Delegating to an Erlang module
/// lets us reuse battle-tested pooling (e.g. poolboy)
/// rather than reimplementing it in Gleam.
///
@external(erlang, "sqlite_pool_ffi", "start_pool")
fn ffi_start_pool(
  pool_name: process.Name(a),
  path: String,
  pool_size: Int,
) -> Result(PoolOps, String)
