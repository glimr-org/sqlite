import gleam/dynamic/decode
import gleeunit/should
import glimr/db/driver
import glimr_sqlite/db/pool
import glimr_sqlite/http/context/ctx
import simplifile
import sqlight

const test_db_1 = "test/fixtures/ctx_test_1.db"

const test_db_2 = "test/fixtures/ctx_test_2.db"

fn cleanup() {
  let _ = simplifile.delete(test_db_1)
  let _ = simplifile.delete(test_db_2)
  let _ = simplifile.create_directory_all("test/fixtures")
  Nil
}

pub fn load_single_default_connection_test() {
  cleanup()

  let connections = [
    driver.SqliteConnection(
      name: "main",
      is_default: True,
      database: Ok(test_db_1),
      pool_size: Ok(2),
    ),
  ]

  let context = ctx.load(connections)

  // Should be able to use the default pool
  pool.get_connection(context.pool, fn(conn) {
    let assert Ok([result]) =
      sqlight.query("SELECT 1 + 1", conn, [], decode.at([0], decode.int))
    result |> should.equal(2)
  })

  // Should also work with pool_for
  pool.get_connection(context.pool_for("main"), fn(conn) {
    let assert Ok([result]) =
      sqlight.query("SELECT 2 + 2", conn, [], decode.at([0], decode.int))
    result |> should.equal(4)
  })

  // Clean up
  pool.stop_pool(context.pool)
  cleanup()
}

pub fn load_multiple_connections_test() {
  cleanup()

  let connections = [
    driver.SqliteConnection(
      name: "primary",
      is_default: True,
      database: Ok(test_db_1),
      pool_size: Ok(2),
    ),
    driver.SqliteConnection(
      name: "secondary",
      is_default: False,
      database: Ok(test_db_2),
      pool_size: Ok(2),
    ),
  ]

  let context = ctx.load(connections)

  // Default pool should be primary
  let _ =
    pool.get_connection(context.pool, fn(conn) {
      let assert Ok(_) =
        sqlight.exec("CREATE TABLE primary_marker (id INTEGER)", conn)
    })

  // Verify primary has the table
  pool.get_connection(context.pool_for("primary"), fn(conn) {
    let decoder = decode.at([0], decode.string)
    let assert Ok(tables) =
      sqlight.query(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='primary_marker'",
        conn,
        [],
        decoder,
      )
    tables |> should.equal(["primary_marker"])
  })

  // Secondary should not have the table
  pool.get_connection(context.pool_for("secondary"), fn(conn) {
    let decoder = decode.at([0], decode.string)
    let assert Ok(tables) =
      sqlight.query(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='primary_marker'",
        conn,
        [],
        decoder,
      )
    tables |> should.equal([])
  })

  // Clean up
  pool.stop_pool(context.pool)
  pool.stop_pool(context.pool_for("secondary"))
  cleanup()
}

pub fn load_filters_non_sqlite_connections_test() {
  cleanup()

  let connections = [
    driver.SqliteConnection(
      name: "sqlite_db",
      is_default: True,
      database: Ok(test_db_1),
      pool_size: Ok(2),
    ),
    // This postgres connection should be ignored
    driver.PostgresUriConnection(
      name: "postgres_db",
      is_default: False,
      url: Ok("postgresql://localhost/test"),
      pool_size: Ok(5),
    ),
  ]

  let context = ctx.load(connections)

  // Should work - only sqlite connection is loaded
  pool.get_connection(context.pool, fn(conn) {
    let assert Ok([result]) =
      sqlight.query("SELECT 42", conn, [], decode.at([0], decode.int))
    result |> should.equal(42)
  })

  pool.stop_pool(context.pool)
  cleanup()
}

pub fn pool_for_returns_correct_pool_test() {
  cleanup()

  let connections = [
    driver.SqliteConnection(
      name: "db_a",
      is_default: True,
      database: Ok(test_db_1),
      pool_size: Ok(2),
    ),
    driver.SqliteConnection(
      name: "db_b",
      is_default: False,
      database: Ok(test_db_2),
      pool_size: Ok(2),
    ),
  ]

  let context = ctx.load(connections)

  // Create different tables in each database
  let _ =
    pool.get_connection(context.pool_for("db_a"), fn(conn) {
      let assert Ok(_) = sqlight.exec("CREATE TABLE table_a (x INTEGER)", conn)
    })

  let _ =
    pool.get_connection(context.pool_for("db_b"), fn(conn) {
      let assert Ok(_) = sqlight.exec("CREATE TABLE table_b (y INTEGER)", conn)
    })

  // Verify db_a has table_a but not table_b
  pool.get_connection(context.pool_for("db_a"), fn(conn) {
    let decoder = decode.at([0], decode.string)
    let assert Ok(tables) =
      sqlight.query(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        conn,
        [],
        decoder,
      )
    tables |> should.equal(["table_a"])
  })

  // Verify db_b has table_b but not table_a
  pool.get_connection(context.pool_for("db_b"), fn(conn) {
    let decoder = decode.at([0], decode.string)
    let assert Ok(tables) =
      sqlight.query(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        conn,
        [],
        decoder,
      )
    tables |> should.equal(["table_b"])
  })

  pool.stop_pool(context.pool_for("db_a"))
  pool.stop_pool(context.pool_for("db_b"))
  cleanup()
}
// Note: Testing panic cases (no connections, no default, multiple defaults)
// would require a testing framework that can catch panics.
// These scenarios are documented but not directly testable with gleeunit.
