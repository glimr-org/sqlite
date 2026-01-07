//// Database transaction support for SQLite.
////
//// Provides transaction execution with automatic retry on
//// deadlock errors. Transactions are committed on success
//// or rolled back on error.

import gleam/erlang/process
import gleam/string
import glimr/db/pool_connection.{type DbError, ConnectionError, QueryError}
import glimr_sqlite/db/pool.{type Connection, type Pool, get_connection}
import sqlight

// ------------------------------------------------------------- Public Functions

/// Executes a function within a database transaction. The
/// transaction is committed on success or rolled back on error.
/// The retries parameter controls how many times to retry on
/// deadlock errors.
///
pub fn transaction(
  pool: Pool,
  retries: Int,
  callback: fn(Connection) -> Result(a, DbError),
) -> Result(a, DbError) {
  case retries < 0 {
    True -> Error(ConnectionError("Transaction retries cannot be negative"))
    False -> do_transaction(pool, retries, callback)
  }
}

// ------------------------------------------------------------- Private Functions

/// Internal implementation of transaction execution. Checks out
/// a connection, runs BEGIN/COMMIT/ROLLBACK, and delegates to
/// maybe_retry on failure for deadlock handling.
///
fn do_transaction(
  pool: Pool,
  retries_remaining: Int,
  callback: fn(Connection) -> Result(a, DbError),
) -> Result(a, DbError) {
  get_connection(pool, fn(conn) {
    case sqlight.exec("BEGIN TRANSACTION", conn) {
      Error(e) -> Error(map_error(e))
      Ok(_) -> {
        case callback(conn) {
          Ok(value) -> {
            case sqlight.exec("COMMIT", conn) {
              Ok(_) -> Ok(value)
              Error(e) -> {
                let _ = sqlight.exec("ROLLBACK", conn)
                maybe_retry(pool, retries_remaining, callback, map_error(e))
              }
            }
          }
          Error(e) -> {
            let _ = sqlight.exec("ROLLBACK", conn)
            maybe_retry(pool, retries_remaining, callback, e)
          }
        }
      }
    }
  })
}

/// Handles retry logic for failed transactions. If the error is
/// a deadlock and retries remain, waits with backoff and retries.
/// Otherwise returns the error immediately.
///
fn maybe_retry(
  pool: Pool,
  retries_remaining: Int,
  callback: fn(Connection) -> Result(a, DbError),
  error: DbError,
) -> Result(a, DbError) {
  case is_deadlock_error(error) && retries_remaining > 0 {
    True -> {
      process.sleep(50 * retries_remaining)
      do_transaction(pool, retries_remaining - 1, callback)
    }
    False -> Error(error)
  }
}

/// Checks if an error indicates a deadlock or lock contention.
/// Looks for common SQLite lock-related keywords in the error
/// message to determine if a retry might succeed.
///
fn is_deadlock_error(error: DbError) -> Bool {
  case error {
    QueryError(msg) -> {
      let lower = string.lowercase(msg)
      string.contains(lower, "deadlock")
      || string.contains(lower, "database is locked")
      || string.contains(lower, "busy")
    }
    _ -> False
  }
}

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
