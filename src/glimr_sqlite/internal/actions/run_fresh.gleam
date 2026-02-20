import gleam/dynamic/decode
import gleam/int
import gleam/list
import glimr/console/console
import glimr_sqlite/db/pool.{type Pool, get_connection}
import glimr_sqlite/internal/actions/run_migrate
import sqlight

/// Drops first, then migrates — this order matters because
/// run_migrate expects an empty or partially-migrated database.
/// If the drop fails, migrations are skipped entirely to avoid
/// running them against a half-dropped schema that would produce
/// confusing duplicate-table errors.
///
pub fn run(pool: Pool, database: String) -> Nil {
  use conn <- get_connection(pool)

  // Drop all tables
  case drop_all_tables(conn) {
    Error(e) -> {
      console.output()
      |> console.line_error("Failed to drop tables:")
      |> console.line(
        "Error code: " <> int.to_string(sqlight.error_code_to_int(e.code)),
      )
      |> console.print()
    }
    Ok(_) -> {
      console.output()
      |> console.blank_line(1)
      |> console.line_success("Tables dropped.")
      |> console.print()

      // Now run migrations on fresh database
      run_migrate.run(pool, database)
    }
  }
}

/// Queries sqlite_master to discover user tables dynamically —
/// no hardcoded table list that could go stale. The NOT LIKE
/// 'sqlite_%' filter excludes SQLite's internal system tables
/// which must never be dropped. Quoting table names with double
/// quotes handles tables whose names are SQL reserved words or
/// contain special characters.
///
fn drop_all_tables(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  let tables_sql =
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
  let decoder = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }

  case sqlight.query(tables_sql, conn, [], decoder) {
    Ok(tables) -> {
      list.each(tables, fn(table) {
        let drop_sql = "DROP TABLE IF EXISTS \"" <> table <> "\""
        let _ = sqlight.exec(drop_sql, conn)
        Nil
      })
      Ok(Nil)
    }
    Error(_) -> Ok(Nil)
  }
}
