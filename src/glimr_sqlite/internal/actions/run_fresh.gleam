import gleam/dynamic/decode
import gleam/int
import gleam/list
import glimr/console/console
import glimr_sqlite/db/pool.{type Pool, get_connection}
import glimr_sqlite/internal/actions/run_migrate
import sqlight

/// Drops all tables and re-runs all migrations.
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
      |> console.unpadded()
      |> console.print()

      // Now run migrations on fresh database
      run_migrate.run(pool, database)
    }
  }
}

/// Drops all user tables from the SQLite database.
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
