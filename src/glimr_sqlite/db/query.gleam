//// Query execution for SQLite databases.
////
//// Provides functions for executing SELECT queries and
//// statements that don't return rows like INSERT, UPDATE,
//// DELETE, and DDL statements.

import gleam/dynamic/decode.{type Decoder}
import glimr/db/pool_connection.{type DbError, QueryError}
import glimr_sqlite/db/pool.{type Connection}
import sqlight

// ------------------------------------------------------------- Public Functions

/// Executes a SELECT query and decodes the results using the
/// provided decoder. Returns a list of decoded rows on success
/// or a database error on failure.
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

/// Executes a SQL statement that does not return rows, such as
/// INSERT, UPDATE, DELETE, or DDL statements. Returns Ok on
/// success or a database error on failure.
///
pub fn exec(conn: Connection, sql: String) -> Result(Nil, DbError) {
  case sqlight.exec(sql, conn) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(map_error(e))
  }
}

// ------------------------------------------------------------- Private Functions

/// Converts a sqlight.Error to a DbError. Extracts the error
/// code and message from the SQLite error and formats them
/// into a QueryError with a descriptive message.
///
fn map_error(e: sqlight.Error) -> DbError {
  case e {
    sqlight.SqlightError(code, msg, _) ->
      QueryError(sqlight_error_message(code, msg))
  }
}

/// Formats a SQLite error code and message into a readable
/// string. Maps constraint error codes to descriptive names
/// like UNIQUE_CONSTRAINT or FOREIGN_KEY.
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
