import glimr/console/command.{type Args, type Command, Flag}
import glimr_sqlite/console/command as command_sqlite
import glimr_sqlite/db/pool.{type Pool}
import glimr_sqlite/internal/actions/run_fresh
import glimr_sqlite/internal/actions/run_migrate

/// The name of the console command.
const name = "sqlite:migrate"

/// The console command description.
const description = "Run pending SQLite migrations"

/// Define the console command and its properties.
///
pub fn command() -> Command {
  command.new()
  |> command.name(name)
  |> command.description(description)
  |> command.args([
    Flag(
      name: "fresh",
      short: "f",
      description: "Drop all tables and re-run all migrations",
    ),
    Flag(
      name: "status",
      short: "s",
      description: "Show migration status without running",
    ),
  ])
  |> command_sqlite.handler(run)
}

/// Execute the console command.
///
fn run(args: Args, pool: Pool) -> Nil {
  let database = command.get_option(args, "database")
  let fresh = command.has_flag(args, "fresh")
  let status = command.has_flag(args, "status")

  case status {
    True -> run_migrate.show_status(pool, database)
    False -> {
      case fresh {
        True -> run_fresh.run(pool, database)
        False -> run_migrate.run(pool, database)
      }
    }
  }
}
