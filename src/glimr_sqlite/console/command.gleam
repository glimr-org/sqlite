//// SQLite Command Support
////
//// Provides helpers for creating console commands that need
//// SQLite database access. The handler function wraps your
//// command logic with automatic pool management.

import gleam/list
import gleam/string
import glimr/console/command.{type Command, type ParsedArgs, CommandWithDb}
import glimr/console/console
import glimr/db/driver.{SqliteConnection}
import glimr/db/pool_connection
import glimr_sqlite/db/pool.{type Pool}

// ------------------------------------------------------------- Public Functions

/// Sets a database handler for a command. Automatically:
/// - Adds the --database option
/// - Validates the connection exists and is SQLite
/// - Starts a typed pool
/// - Calls your handler with the pool
/// - Stops the pool when done
///
/// Your handler receives a fully typed `glimr_sqlite.Pool`.
///
pub fn handler(cmd: Command, db_handler: fn(ParsedArgs, Pool) -> Nil) -> Command {
  // Add --database option to existing args
  let new_args = list.append(cmd.args, [command.db_option()])

  CommandWithDb(
    name: cmd.name,
    description: cmd.description,
    args: new_args,
    driver_type: driver.Sqlite,
    run_with_pool: fn(args, conn) {
      case conn {
        SqliteConnection(_, path, pool_size) -> {
          case path, pool_size {
            Ok(p), Ok(ps) -> {
              let config = pool_connection.SqliteConfig(p, ps)
              case pool.start_pool(config) {
                Ok(p) -> {
                  db_handler(args, p)
                  pool.stop_pool(p)
                }
                Error(e) -> {
                  console.output()
                  |> console.line_error("Failed to start SQLite pool:")
                  |> console.line(string.inspect(e))
                  |> console.print()
                }
              }
            }
            _, _ -> {
              console.output()
              |> console.line_error(
                "SQLite connection is missing required configuration.",
              )
              |> console.print()
            }
          }
        }
        _ -> {
          console.output()
          |> console.line_error(
            "Connection is not SQLite. Use postgres:* commands instead.",
          )
          |> console.print()
        }
      }
    },
  )
}
