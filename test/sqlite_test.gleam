import gleam/dynamic/decode
import gleeunit/should
import glimr/db/driver.{SqliteConnection}
import glimr_sqlite/db/pool
import glimr_sqlite/sqlite
import simplifile
import sqlight

const test_db = "test/fixtures/sqlite_test.db"

// ------------------------------------------------------------- start

pub fn start_with_valid_connection_test() {
  // Clean up any existing test db
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let connections = [
    SqliteConnection(
      name: "main",
      is_default: True,
      database: Ok(test_db),
      pool_size: Ok(2),
    ),
  ]

  let p = sqlite.start("main", connections)

  // Verify the pool works by executing a query
  let result =
    pool.get_connection(p, fn(conn) {
      sqlight.query("SELECT 1 + 1 as result", conn, [], decode.at([0], decode.int))
    })

  result |> should.be_ok
  let assert Ok(rows) = result
  rows |> should.equal([2])

  pool.stop_pool(p)
  let _ = simplifile.delete(test_db)
  Nil
}

pub fn start_with_multiple_connections_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.delete("test/fixtures/sqlite_secondary.db")
  let _ = simplifile.create_directory_all("test/fixtures")

  let connections = [
    SqliteConnection(
      name: "main",
      is_default: True,
      database: Ok(test_db),
      pool_size: Ok(2),
    ),
    SqliteConnection(
      name: "secondary",
      is_default: False,
      database: Ok("test/fixtures/sqlite_secondary.db"),
      pool_size: Ok(1),
    ),
  ]

  // Start the secondary connection
  let p = sqlite.start("secondary", connections)

  // Verify it works
  let result =
    pool.get_connection(p, fn(conn) {
      sqlight.query("SELECT 42", conn, [], decode.at([0], decode.int))
    })

  result |> should.be_ok
  let assert Ok(rows) = result
  rows |> should.equal([42])

  pool.stop_pool(p)
  let _ = simplifile.delete(test_db)
  let _ = simplifile.delete("test/fixtures/sqlite_secondary.db")
  Nil
}

pub fn start_creates_usable_pool_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let connections = [
    SqliteConnection(
      name: "test",
      is_default: True,
      database: Ok(test_db),
      pool_size: Ok(3),
    ),
  ]

  let p = sqlite.start("test", connections)

  // Create a table and insert data
  let _ =
    pool.get_connection(p, fn(conn) {
      sqlight.exec("CREATE TABLE test_items (id INTEGER PRIMARY KEY, name TEXT)", conn)
    })

  let _ =
    pool.get_connection(p, fn(conn) {
      sqlight.exec("INSERT INTO test_items (name) VALUES ('item1')", conn)
    })

  // Query the data back
  let result =
    pool.get_connection(p, fn(conn) {
      sqlight.query(
        "SELECT name FROM test_items WHERE id = 1",
        conn,
        [],
        decode.at([0], decode.string),
      )
    })

  result |> should.be_ok
  let assert Ok(rows) = result
  rows |> should.equal(["item1"])

  pool.stop_pool(p)
  let _ = simplifile.delete(test_db)
  Nil
}
