import gleam/dynamic/decode
import gleeunit/should
import glimr/db/db
import glimr/db/migrate
import glimr_sqlite/sqlite
import simplifile

const test_db = "test/fixtures/migrate_test.db"

fn with_connection(f: fn(db.Connection) -> a) -> a {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 1)
  let core_pool = sqlite.start_from_config(config)

  use conn <- db.get_connection(core_pool)
  let result = f(conn)

  db.stop_pool(core_pool)
  let _ = simplifile.delete(test_db)
  result
}

pub fn ensure_table_creates_migrations_table_test() {
  with_connection(fn(conn) {
    let result = migrate.ensure_table(conn)
    result |> should.be_ok

    // Verify table exists
    let decoder = decode.at([0], decode.string)
    case
      db.query_with(
        conn,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='_glimr_migrations'",
        [],
        decoder,
      )
    {
      Ok(db.QueryResult(_, tables)) ->
        tables |> should.equal(["_glimr_migrations"])
      _ -> panic as "Expected one table"
    }
  })
}

pub fn ensure_table_idempotent_test() {
  with_connection(fn(conn) {
    // Call twice - should not error
    let assert Ok(_) = migrate.ensure_table(conn)
    let result = migrate.ensure_table(conn)

    result |> should.be_ok
  })
}

pub fn get_applied_empty_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    let result = migrate.get_applied(conn)

    result |> should.be_ok
    let assert Ok(versions) = result
    versions |> should.equal([])
  })
}

pub fn get_applied_returns_versions_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    // Insert some migration records
    let assert Ok(_) =
      db.exec_with(conn, "INSERT INTO _glimr_migrations (version) VALUES ($1)", [
        db.string("001"),
      ])
    let assert Ok(_) =
      db.exec_with(conn, "INSERT INTO _glimr_migrations (version) VALUES ($1)", [
        db.string("002"),
      ])

    let result = migrate.get_applied(conn)

    result |> should.be_ok
    let assert Ok(versions) = result
    versions |> should.equal(["001", "002"])
  })
}

pub fn get_applied_sorted_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    // Insert out of order
    let assert Ok(_) =
      db.exec_with(conn, "INSERT INTO _glimr_migrations (version) VALUES ($1)", [
        db.string("003"),
      ])
    let assert Ok(_) =
      db.exec_with(conn, "INSERT INTO _glimr_migrations (version) VALUES ($1)", [
        db.string("001"),
      ])
    let assert Ok(_) =
      db.exec_with(conn, "INSERT INTO _glimr_migrations (version) VALUES ($1)", [
        db.string("002"),
      ])

    let result = migrate.get_applied(conn)

    result |> should.be_ok
    let assert Ok(versions) = result
    versions |> should.equal(["001", "002", "003"])
  })
}

pub fn apply_pending_empty_list_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    let result = migrate.apply_pending(conn, [])

    result |> should.be_ok
    let assert Ok(applied) = result
    applied |> should.equal([])
  })
}

pub fn apply_pending_single_migration_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    let migration =
      migrate.Migration(
        version: "001",
        name: "create_users",
        sql: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
      )

    let result = migrate.apply_pending(conn, [migration])

    result |> should.be_ok
    let assert Ok(applied) = result
    applied |> should.equal(["001"])

    // Verify table was created
    let decoder = decode.at([0], decode.string)
    case
      db.query_with(
        conn,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='users'",
        [],
        decoder,
      )
    {
      Ok(db.QueryResult(_, tables)) -> tables |> should.equal(["users"])
      _ -> panic as "Expected users table"
    }

    // Verify migration was recorded
    let assert Ok(versions) = migrate.get_applied(conn)
    versions |> should.equal(["001"])
  })
}

pub fn apply_pending_multiple_migrations_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    let migrations = [
      migrate.Migration(
        version: "001",
        name: "create_users",
        sql: "CREATE TABLE users (id INTEGER PRIMARY KEY)",
      ),
      migrate.Migration(
        version: "002",
        name: "create_posts",
        sql: "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER)",
      ),
    ]

    let result = migrate.apply_pending(conn, migrations)

    result |> should.be_ok
    let assert Ok(applied) = result
    applied |> should.equal(["001", "002"])

    // Verify both migrations recorded
    let assert Ok(versions) = migrate.get_applied(conn)
    versions |> should.equal(["001", "002"])
  })
}

pub fn apply_pending_multiple_statements_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    let migration =
      migrate.Migration(
        version: "001",
        name: "multi_statement",
        sql: "CREATE TABLE a (id INTEGER); CREATE TABLE b (id INTEGER)",
      )

    let result = migrate.apply_pending(conn, [migration])

    result |> should.be_ok

    // Verify both tables created
    let decoder = decode.at([0], decode.string)
    case
      db.query_with(
        conn,
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('a', 'b') ORDER BY name",
        [],
        decoder,
      )
    {
      Ok(db.QueryResult(_, tables)) -> tables |> should.equal(["a", "b"])
      _ -> panic as "Expected two tables"
    }
  })
}

pub fn apply_pending_stops_on_error_test() {
  with_connection(fn(conn) {
    let assert Ok(_) = migrate.ensure_table(conn)

    let migrations = [
      migrate.Migration(
        version: "001",
        name: "good",
        sql: "CREATE TABLE good (id INTEGER)",
      ),
      migrate.Migration(version: "002", name: "bad", sql: "INVALID SQL HERE"),
      migrate.Migration(
        version: "003",
        name: "never_runs",
        sql: "CREATE TABLE never (id INTEGER)",
      ),
    ]

    let result = migrate.apply_pending(conn, migrations)

    result |> should.be_error

    // Only first migration should be applied
    let assert Ok(versions) = migrate.get_applied(conn)
    versions |> should.equal(["001"])
  })
}
