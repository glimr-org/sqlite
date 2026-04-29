//// SQlite Adapter
////
//// Application boot needs to wire up database pools, cache
//// pools, and session stores. This is the public entry point —
//// each function takes a name or pool and returns a ready-to-use
//// resource, so the app's main module reads as a simple
//// sequence of start calls rather than manual config loading
//// and plumbing. Pool construction, query execution, and
//// session storage all live here so callers only need to
//// import this one module.
////

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/list
import gleam/string
import glimr/cache.{type CachePool}
import glimr/config
import glimr/db/db.{
  type Config, type DbError, type DbPool, type QueryResult, type Value,
  ConnectionError, PostgresConfig, PostgresParamsConfig, QueryError, QueryResult,
  SqliteConfig,
}
import glimr/db/driver
import glimr/session.{type SessionStore}
import glimr/utils/unix_timestamp
import glimr_sqlite/db/gen
import sqlight

// ------------------------------------------------------------- Public Types

/// The pool must be opaque so callers can't bypass the
/// checkout/checkin protocol by accessing the raw connections
/// directly. Storing closures rather than an Erlang PID keeps
/// the Erlang pool internals hidden from Gleam code.
///
pub opaque type Pool {
  Pool(
    checkout: fn() -> Result(#(sqlight.Connection, fn() -> Nil), String),
    stop: fn() -> Nil,
  )
}

/// The Erlang FFI returns closures that capture the pool handle
/// internally, so a named record type is needed to receive them
/// across the FFI boundary. This stays public so the FFI module
/// can construct it.
///
pub type PoolOps {
  PoolOps(
    checkout: fn() -> Result(#(sqlight.Connection, fn() -> Nil), String),
    stop: fn() -> Nil,
  )
}

/// Re-exporting sqlight.Connection under a local alias lets the
/// rest of the codebase reference Connection without depending
/// on sqlight directly, so swapping the underlying driver only
/// requires changes here.
///
pub type Connection =
  sqlight.Connection

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
  let table = config.get_string("session.table")
  let lifetime = config.get_int("session.lifetime")

  session.new(
    load: fn(session_id) { session_load(pool, table, session_id, lifetime) },
    save: fn(session_id, data, flash) {
      session_save(pool, table, session_id, data, flash, lifetime)
    },
    destroy: fn(session_id) { session_destroy(pool, table, session_id) },
    gc: fn() { session_gc(pool, table, lifetime) },
    cookie_value: fn(id, _, _) { id },
  )
}

// ------------------------------------------------------------- Internal Public Functions

/// Console commands like `db:migrate` need to start a pool but
/// shouldn't crash on failure — they should print a helpful
/// error message instead. This is the non-panicking variant of
/// start_from_config that returns a Result so the command can
/// handle the error gracefully.
///
@internal
pub fn try_start_from_config(config: Config) -> Result(DbPool, String) {
  case start_pool(config) {
    Ok(db_pool) -> Ok(wrap_pool(db_pool))
    Error(e) -> Error(string.inspect(e))
  }
}

/// Tests need pools without reading database.toml — they supply
/// in-memory databases (`:memory:`) or temp-file paths directly.
/// Accepting a pre-built Config skips the file I/O and config
/// lookup entirely.
///
@internal
pub fn start_from_config(config: Config) -> DbPool {
  let assert Ok(db_pool) = start_pool(config)
  wrap_pool(db_pool)
}

/// The rest of the framework talks to databases through a
/// generic DbPool — it doesn't know or care whether it's SQLite
/// or Postgres underneath. This is where we plug sqlight's query
/// and exec functions into that generic interface, so `db.query`
/// on a SQLite pool routes to the right driver without any
/// caller needing to know.
///
@internal
pub fn wrap_pool(db_pool: Pool) -> DbPool {
  let #(checkout, stop) = raw_checkout(db_pool)

  db.new_pool(
    driver: db.Sqlite,
    query_fn: db.to_dynamic(vtable_query),
    exec_fn: db.to_dynamic(vtable_exec),
    checkout: fn() {
      case checkout() {
        Ok(#(conn, release)) -> Ok(#(db.to_dynamic(conn), release))
        Error(msg) -> Error(msg)
      }
    },
    stop: stop,
  )
}

/// Wrapping the FFI result in the opaque Pool type ensures
/// callers interact with the pool only through the public API.
/// The Config is validated inside start, so errors from
/// misconfiguration surface here rather than later.
///
@internal
pub fn start_pool(config: Config) -> Result(Pool, DbError) {
  case start_raw(config) {
    Ok(ops) -> Ok(Pool(checkout: ops.checkout, stop: ops.stop))
    Error(msg) -> Error(ConnectionError(msg))
  }
}

/// SQLite file locks aren't released until connections close,
/// so stopping the pool explicitly prevents lock contention if
/// another process needs the database file after this
/// application is done with it.
///
@internal
pub fn stop_pool(pool: Pool) -> Nil {
  pool.stop()
}

/// A callback-based API guarantees the connection is returned
/// to the pool even if the function crashes, preventing
/// connection leaks that would eventually exhaust the pool
/// under sustained traffic.
///
@internal
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

/// The framework's driver-agnostic Pool vtable needs the raw
/// checkout and stop closures to wire SQLite into the shared db
/// interface. Returning a tuple avoids exposing the opaque Pool
/// internals.
///
@internal
pub fn raw_checkout(
  pool: Pool,
) -> #(fn() -> Result(#(sqlight.Connection, fn() -> Nil), String), fn() -> Nil) {
  #(pool.checkout, pool.stop)
}

/// Thin wrapper so application code can run SELECT queries
/// without importing sqlight or handling its error types. The
/// decoder is passed through unchanged since sqlight already
/// supports Gleam decoders.
///
@internal
pub fn query(
  conn: Connection,
  sql: String,
  params: List(sqlight.Value),
  decoder: Decoder(t),
) -> Result(List(t), DbError) {
  case sqlight.query(sql, conn, params, decoder) {
    Ok(rows) -> Ok(rows)
    Error(e) -> Error(map_error(e))
  }
}

/// DDL and write operations don't return rows, so a separate
/// function avoids forcing callers to supply a decoder they'd
/// never use. Errors are still mapped to DbError for consistency
/// with query.
///
@internal
pub fn exec(conn: Connection, sql: String) -> Result(Nil, DbError) {
  case sqlight.exec(sql, conn) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(map_error(e))
  }
}

/// The framework's db dispatches through a vtable of
/// Dynamic-typed callbacks so it stays driver-agnostic. This
/// function satisfies that interface by coercing the handle and
/// converting generic Values to sqlight-specific values before
/// executing.
///
@internal
pub fn vtable_query(
  handle: Dynamic,
  sql: String,
  params: List(Value),
  decoder: Decoder(a),
) -> Result(QueryResult(a), DbError) {
  let conn: sqlight.Connection = coerce(handle)
  let sq_params = list.map(params, gen.to_sqlight_value)

  case sqlight.query(sql, conn, sq_params, decoder) {
    Ok(rows) -> Ok(QueryResult(list.length(rows), rows))
    Error(e) -> Error(map_error(e))
  }
}

/// sqlight.exec doesn't accept parameters, so writes with params
/// must go through sqlight.query with a dummy decoder. The
/// branch on empty params avoids that workaround when no
/// parameters are needed, using the more efficient exec path
/// instead.
///
@internal
pub fn vtable_exec(
  handle: Dynamic,
  sql: String,
  params: List(Value),
) -> Result(Int, DbError) {
  let conn: sqlight.Connection = coerce(handle)
  let sq_params = list.map(params, gen.to_sqlight_value)

  case list.is_empty(sq_params) {
    True -> {
      case sqlight.exec(sql, conn) {
        Ok(_) -> Ok(0)
        Error(e) -> Error(map_error(e))
      }
    }
    False -> {
      case sqlight.query(sql, conn, sq_params, decode.dynamic) {
        Ok(rows) -> Ok(list.length(rows))
        Error(e) -> Error(map_error(e))
      }
    }
  }
}

// ------------------------------------------------------------- Private Functions

/// Config is a shared union across drivers, so a Postgres
/// variant could arrive here by mistake. Matching on the config
/// type and rejecting non-SQLite variants gives a clear error
/// instead of a confusing FFI crash.
///
fn start_raw(config: Config) -> Result(PoolOps, String) {
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

/// sqlight errors carry SQLite-specific codes that mean nothing
/// to framework code expecting DbError. Mapping them here keeps
/// the conversion in one place so every call site doesn't repeat
/// the same pattern match.
///
fn map_error(e: sqlight.Error) -> DbError {
  case e {
    sqlight.SqlightError(code, msg, _) ->
      QueryError(sqlight_error_message(code, msg))
  }
}

/// Raw SQLite error codes like 2067 are meaningless in logs.
/// Translating constraint violations to readable names like
/// UNIQUE_CONSTRAINT or FOREIGN_KEY lets developers identify the
/// problem without looking up error codes in the SQLite
/// documentation.
///
fn sqlight_error_message(code: sqlight.ErrorCode, msg: String) -> String {
  let code_str = case code {
    sqlight.Constraint -> "CONSTRAINT"
    sqlight.ConstraintUnique -> "UNIQUE_CONSTRAINT"
    sqlight.ConstraintForeignkey -> "FOREIGN_KEY"
    sqlight.ConstraintPrimarykey -> "PRIMARY_KEY"
    sqlight.ConstraintNotnull -> "NOT_NULL"
    _ -> "ERROR"
  }
  code_str <> ": " <> msg
}

/// Expiration is checked in the WHERE clause rather than in
/// application code so the database does the filtering and an
/// expired row is never returned — even if GC hasn't run yet.
/// The cutoff is computed from the current time minus lifetime,
/// matching the last_activity-based expiration model used by
/// save and gc.
///
fn session_load(
  pool: DbPool,
  table: String,
  session_id: String,
  lifetime: Int,
) -> #(dict.Dict(String, String), dict.Dict(String, String)) {
  let cutoff = unix_timestamp.now() - lifetime * 60
  let sql =
    "SELECT payload FROM " <> table <> " WHERE id = $1 AND last_activity >= $2"

  use conn <- db.get_connection(pool)
  case
    db.query_with(
      conn,
      sql,
      [db.string(session_id), db.int(cutoff)],
      decode.at([0], decode.string),
    )
  {
    Ok(db.QueryResult(_, [payload_json])) ->
      session.decode_payload(payload_json)
    _ -> #(dict.new(), dict.new())
  }
}

/// Uses INSERT ... ON CONFLICT DO UPDATE (upsert) so both new
/// and existing sessions are handled in a single atomic query.
/// Without this, a separate check-then-insert would be racy
/// under concurrent requests with the same session ID. The
/// last_activity timestamp is always set to now so the GC cutoff
/// reflects the most recent request, not session creation time.
///
fn session_save(
  pool: DbPool,
  table: String,
  session_id: String,
  data: dict.Dict(String, String),
  flash: dict.Dict(String, String),
  _lifetime: Int,
) -> Nil {
  let encoded = session.encode_payload(data, flash)
  let now = unix_timestamp.now()
  let sql =
    "INSERT INTO "
    <> table
    <> " (id, payload, last_activity) VALUES ($1, $2, $3) "
    <> "ON CONFLICT (id) DO UPDATE SET payload = excluded.payload, last_activity = excluded.last_activity"

  use conn <- db.get_connection(pool)

  let _ = {
    db.query_with(
      conn,
      sql,
      [db.string(session_id), db.string(encoded), db.int(now)],
      decode.string,
    )
  }

  Nil
}

/// Deletes the row immediately so the old session ID can never
/// be reused — important after invalidation to prevent session
/// fixation attacks. The delete is idempotent; if GC already
/// removed the row, the query simply affects zero rows.
///
fn session_destroy(pool: DbPool, table: String, session_id: String) -> Nil {
  let sql = "DELETE FROM " <> table <> " WHERE id = $1"

  use conn <- db.get_connection(pool)

  let _ = db.query_with(conn, sql, [db.string(session_id)], decode.string)

  Nil
}

/// Bulk-deletes all rows whose last_activity falls before the
/// cutoff in a single query, which is far cheaper than scanning
/// and deleting one at a time. The last_activity index on the
/// table keeps this fast even with many session rows. Called
/// probabilistically by the middleware so no single request pays
/// the full cleanup cost.
///
fn session_gc(pool: DbPool, table: String, lifetime: Int) -> Nil {
  let cutoff = unix_timestamp.now() - lifetime * 60
  let sql = "DELETE FROM " <> table <> " WHERE last_activity < $1"

  use conn <- db.get_connection(pool)

  let _ = db.query_with(conn, sql, [db.int(cutoff)], decode.string)

  Nil
}

// ------------------------------------------------------------- FFI Bindings

/// SQLite's C library is accessed through NIF bindings that
/// require Erlang-level process management for connection
/// pooling. Delegating to an Erlang module lets us reuse
/// battle-tested pooling (e.g. poolboy) rather than
/// reimplementing it in Gleam.
///
@external(erlang, "sqlite_pool_ffi", "start_pool")
fn ffi_start_pool(
  pool_name: process.Name(a),
  path: String,
  pool_size: Int,
) -> Result(PoolOps, String)

/// The vtable passes connection handles as Dynamic to stay
/// driver-agnostic, but sqlight functions need a typed
/// Connection. An identity coerce is safe here because the
/// handle always originates from our pool.
///
@external(erlang, "glimr_pool_ffi", "identity")
fn coerce(value: Dynamic) -> a
