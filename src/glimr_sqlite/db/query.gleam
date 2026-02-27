//// SQLite Query Execution
////
//// The sqlight library returns its own error types
//// but the rest of the framework expects DbError.
//// This module bridges that gap — wrapping sqlight
//// calls so all query errors surface as the unified
//// DbError type and callers never depend on sqlight
//// directly.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import glimr/db/db.{
  type DbError, type QueryResult, type Value, QueryError, QueryResult,
}
import glimr_sqlite/db/gen
import sqlight

// ------------------------------------------------------------- Public Types

/// Aliasing sqlight.Connection locally lets downstream code
/// reference Connection without importing sqlight directly, so 
/// the driver can be swapped without touching every call site.
///
pub type Connection =
  sqlight.Connection

// ------------------------------------------------------------- Public Functions

/// Thin wrapper so application code can run SELECT queries 
/// without importing sqlight or handling its error types. The 
/// decoder is passed through unchanged since sqlight already 
/// supports Gleam decoders.
///
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
pub fn exec(conn: Connection, sql: String) -> Result(Nil, DbError) {
  case sqlight.exec(sql, conn) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(map_error(e))
  }
}

/// The framework's db dispatches through a vtable 
/// of Dynamic-typed callbacks so it stays driver-agnostic. This 
/// function satisfies that interface by coercing the handle and 
/// converting generic Values to sqlight-specific values before 
/// executing.
///
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

/// sqlight.exec doesn't accept parameters, so writes with 
/// params must go through sqlight.query with a dummy decoder. 
/// The branch on empty params avoids that workaround when no 
/// parameters are needed, using the more efficient exec path 
/// instead.
///
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

/// sqlight errors carry SQLite-specific codes that mean nothing 
/// to framework code expecting DbError. Mapping them here keeps 
/// the conversion in one place so every call site doesn't 
/// repeat the same pattern match.
///
fn map_error(e: sqlight.Error) -> DbError {
  case e {
    sqlight.SqlightError(code, msg, _) ->
      QueryError(sqlight_error_message(code, msg))
  }
}

/// Raw SQLite error codes like 2067 are meaningless in logs. 
/// Translating constraint violations to readable names like 
/// UNIQUE_CONSTRAINT or FOREIGN_KEY lets developers identify 
/// the problem without looking up error codes in the SQLite 
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

// ------------------------------------------------------------- FFI Bindings

/// The vtable passes connection handles as Dynamic to stay 
/// driver-agnostic, but sqlight functions need a typed 
/// Connection. An identity coerce is safe here because the 
/// handle always originates from our pool.
///
@external(erlang, "glimr_pool_ffi", "identity")
fn coerce(value: Dynamic) -> a
