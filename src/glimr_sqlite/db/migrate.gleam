//// SQLite Migration Database Operations
////
//// Provides database operations for running migrations. Handles
//// the migrations tracking table and applying migration SQL
//// to the database.

import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import glimr/db/migrate as framework_migrate
import glimr_sqlite/db/pool.{type Connection}
import sqlight

// ------------------------------------------------------------- Public Functions

/// Creates the migrations tracking table if it doesn't exist.
/// Uses _glimr_migrations to track which migrations have been
/// applied to the database.
///
pub fn ensure_table(conn: Connection) -> Result(Nil, sqlight.Error) {
  sqlight.exec(
    "CREATE TABLE IF NOT EXISTS _glimr_migrations (
      version TEXT PRIMARY KEY,
      applied_at TEXT DEFAULT CURRENT_TIMESTAMP
    )",
    conn,
  )
}

/// Gets the list of applied migration versions from the database.
/// Returns versions in sorted order for comparison against
/// available migration files.
///
pub fn get_applied(conn: Connection) -> Result(List(String), sqlight.Error) {
  let sql = "SELECT version FROM _glimr_migrations ORDER BY version"
  let decoder = {
    use version <- decode.field(0, decode.string)
    decode.success(version)
  }

  sqlight.query(sql, conn, [], decoder)
}

/// Applies a list of migrations, stopping on first error.
/// Returns the list of successfully applied version strings
/// or the first error encountered.
///
pub fn apply_pending(
  conn: Connection,
  pending: List(framework_migrate.Migration),
) -> Result(List(String), sqlight.Error) {
  do_apply_pending(conn, pending, [])
}

// ------------------------------------------------------------- Private Functions

/// Recursive implementation of apply_pending that accumulates
/// applied versions. Processes migrations one at a time and
/// stops on first error.
///
fn do_apply_pending(
  conn: Connection,
  pending: List(framework_migrate.Migration),
  applied: List(String),
) -> Result(List(String), sqlight.Error) {
  case pending {
    [] -> Ok(list.reverse(applied))
    [migration, ..rest] -> {
      case apply_single(conn, migration) {
        Ok(_) -> do_apply_pending(conn, rest, [migration.version, ..applied])
        Error(err) -> Error(err)
      }
    }
  }
}

/// Applies a single migration and records it in the tracking
/// table. Splits SQL into statements and executes each one
/// sequentially.
///
fn apply_single(
  conn: Connection,
  migration: framework_migrate.Migration,
) -> Result(Nil, sqlight.Error) {
  let sql = framework_migrate.extract_sql(migration.sql)

  let statements =
    sql
    |> string.split(";")
    |> list.map(string.trim)
    |> list.filter(fn(s) { s != "" })

  case execute_statements(conn, statements) {
    Ok(_) -> {
      sqlight.query(
        "INSERT INTO _glimr_migrations (version) VALUES (?)",
        conn,
        [sqlight.text(migration.version)],
        decode.dynamic,
      )
      |> result.map(fn(_) { Nil })
    }
    Error(err) -> Error(err)
  }
}

/// Executes a list of SQL statements sequentially. Processes
/// each statement in order and stops on first error, returning
/// the error to the caller.
///
fn execute_statements(
  conn: Connection,
  statements: List(String),
) -> Result(Nil, sqlight.Error) {
  case statements {
    [] -> Ok(Nil)
    [stmt, ..rest] -> {
      case sqlight.exec(stmt, conn) {
        Ok(_) -> execute_statements(conn, rest)
        Error(err) -> Error(err)
      }
    }
  }
}
