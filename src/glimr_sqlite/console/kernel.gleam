//// glimr_sqlite Console Kernel
////
//// Provides SQLite-specific console commands for database
//// operations. Users register these commands in their
//// command_provider to enable sqlite:migrate, sqlite:gen,
//// and sqlite:cache-table.

import glimr/console/command.{type Command}
import glimr_sqlite/internal/console/commands/sqlite_cache_table
import glimr_sqlite/internal/console/commands/sqlite_gen
import glimr_sqlite/internal/console/commands/sqlite_migrate

// ------------------------------------------------------------- Public Functions

/// Returns the list of SQLite console commands. Add these to
/// your command_provider to enable sqlite:migrate, sqlite:gen,
/// and sqlite:cache-table commands.
///
/// *Example:*
///
/// ```gleam
/// import glimr_sqlite/console/kernel as sqlite_kernel
///
/// pub fn register() -> List(Command) {
///   list.flatten([
///     kernel.commands(),
///     sqlite_kernel.commands(),
///   ])
/// }
/// ```
///
pub fn commands() -> List(Command) {
  [
    sqlite_migrate.command(),
    sqlite_gen.command(),
    sqlite_cache_table.command(),
  ]
}
