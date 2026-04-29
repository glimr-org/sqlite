import gleam/dynamic/decode
import gleeunit/should
import glimr/db/db
import glimr_sqlite/sqlite
import simplifile
import sqlight

const test_db = "test/fixtures/pool_test.db"

pub fn start_pool_with_valid_config_test() {
  // Clean up any existing test db
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 2)
  let result = sqlite.start_pool(config)

  result |> should.be_ok

  let assert Ok(p) = result
  sqlite.stop_pool(p)

  // Clean up
  let _ = simplifile.delete(test_db)
  Nil
}

pub fn start_pool_with_invalid_path_test() {
  let config = db.SqliteConfig("/nonexistent/path/db.sqlite", 2)
  let result = sqlite.start_pool(config)

  result |> should.be_error
}

pub fn stop_pool_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 2)
  let assert Ok(p) = sqlite.start_pool(config)

  // Should not panic
  sqlite.stop_pool(p)

  // Clean up
  let _ = simplifile.delete(test_db)
  Nil
}

pub fn get_connection_executes_query_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 2)
  let assert Ok(p) = sqlite.start_pool(config)

  let result =
    sqlite.get_connection(p, fn(conn) {
      sqlight.query(
        "SELECT 1 + 1 as result",
        conn,
        [],
        decode.at([0], decode.int),
      )
    })

  result |> should.be_ok
  let assert Ok(rows) = result
  rows |> should.equal([2])

  sqlite.stop_pool(p)
  let _ = simplifile.delete(test_db)
  Nil
}

pub fn get_connection_multiple_times_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 2)
  let assert Ok(p) = sqlite.start_pool(config)

  // Get connection multiple times
  let r1 =
    sqlite.get_connection(p, fn(conn) {
      sqlight.query("SELECT 1", conn, [], decode.at([0], decode.int))
    })
  let r2 =
    sqlite.get_connection(p, fn(conn) {
      sqlight.query("SELECT 2", conn, [], decode.at([0], decode.int))
    })
  let r3 =
    sqlite.get_connection(p, fn(conn) {
      sqlight.query("SELECT 3", conn, [], decode.at([0], decode.int))
    })

  r1 |> should.be_ok
  r2 |> should.be_ok
  r3 |> should.be_ok

  let assert Ok([v1]) = r1
  let assert Ok([v2]) = r2
  let assert Ok([v3]) = r3

  v1 |> should.equal(1)
  v2 |> should.equal(2)
  v3 |> should.equal(3)

  sqlite.stop_pool(p)
  let _ = simplifile.delete(test_db)
  Nil
}
