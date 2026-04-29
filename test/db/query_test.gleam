import gleam/dynamic/decode
import gleeunit/should
import glimr/db/db.{QueryError}
import glimr_sqlite/sqlite
import simplifile
import sqlight

const test_db = "test/fixtures/query_test.db"

fn with_pool(f: fn(sqlite.Pool) -> a) -> a {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 2)
  let assert Ok(p) = sqlite.start_pool(config)

  let result = f(p)

  sqlite.stop_pool(p)
  let _ = simplifile.delete(test_db)
  result
}

pub fn query_select_with_decoder_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      // Create table and insert data
      let assert Ok(_) =
        sqlite.exec(conn, "CREATE TABLE users (id INTEGER, name TEXT)")
      let assert Ok(_) =
        sqlight.query(
          "INSERT INTO users (id, name) VALUES (?, ?)",
          conn,
          [sqlight.int(1), sqlight.text("Alice")],
          decode.dynamic,
        )

      // Query with decoder
      let decoder = {
        use id <- decode.field(0, decode.int)
        use name <- decode.field(1, decode.string)
        decode.success(#(id, name))
      }

      let result = sqlite.query(conn, "SELECT id, name FROM users", [], decoder)

      result |> should.be_ok
      let assert Ok(rows) = result
      rows |> should.equal([#(1, "Alice")])
    })
  })
}

pub fn query_with_parameters_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let assert Ok(_) =
        sqlite.exec(conn, "CREATE TABLE items (id INTEGER, value TEXT)")
      let assert Ok(_) =
        sqlight.query(
          "INSERT INTO items VALUES (1, 'one'), (2, 'two'), (3, 'three')",
          conn,
          [],
          decode.dynamic,
        )

      let decoder = decode.at([1], decode.string)
      let result =
        sqlite.query(
          conn,
          "SELECT * FROM items WHERE id > ?",
          [sqlight.int(1)],
          decoder,
        )

      result |> should.be_ok
      let assert Ok(rows) = result
      rows |> should.equal(["two", "three"])
    })
  })
}

pub fn query_empty_result_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let assert Ok(_) =
        sqlite.exec(conn, "CREATE TABLE empty_table (id INTEGER)")

      let decoder = decode.at([0], decode.int)
      let result = sqlite.query(conn, "SELECT * FROM empty_table", [], decoder)

      result |> should.be_ok
      let assert Ok(rows) = result
      rows |> should.equal([])
    })
  })
}

pub fn query_invalid_sql_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let decoder = decode.at([0], decode.int)
      let result =
        sqlite.query(conn, "SELECT * FROM nonexistent_table", [], decoder)

      result |> should.be_error
      let assert Error(QueryError(msg)) = result
      msg |> should.not_equal("")
    })
  })
}

pub fn exec_create_table_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let result =
        sqlite.exec(conn, "CREATE TABLE test_table (id INTEGER PRIMARY KEY)")

      result |> should.be_ok
    })
  })
}

pub fn exec_insert_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let assert Ok(_) = sqlite.exec(conn, "CREATE TABLE numbers (n INTEGER)")

      let result = sqlite.exec(conn, "INSERT INTO numbers VALUES (42)")

      result |> should.be_ok

      // Verify insertion
      let decoder = decode.at([0], decode.int)
      let assert Ok([n]) =
        sqlite.query(conn, "SELECT n FROM numbers", [], decoder)
      n |> should.equal(42)
    })
  })
}

pub fn exec_update_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let assert Ok(_) =
        sqlite.exec(conn, "CREATE TABLE data (id INTEGER, val INTEGER)")
      let assert Ok(_) = sqlite.exec(conn, "INSERT INTO data VALUES (1, 10)")

      let result = sqlite.exec(conn, "UPDATE data SET val = 20 WHERE id = 1")
      result |> should.be_ok

      let decoder = decode.at([1], decode.int)
      let assert Ok([val]) =
        sqlite.query(conn, "SELECT * FROM data", [], decoder)
      val |> should.equal(20)
    })
  })
}

pub fn exec_delete_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let assert Ok(_) =
        sqlite.exec(conn, "CREATE TABLE to_delete (id INTEGER)")
      let assert Ok(_) =
        sqlite.exec(conn, "INSERT INTO to_delete VALUES (1), (2), (3)")

      let result = sqlite.exec(conn, "DELETE FROM to_delete WHERE id = 2")
      result |> should.be_ok

      let decoder = decode.at([0], decode.int)
      let assert Ok(rows) =
        sqlite.query(conn, "SELECT * FROM to_delete ORDER BY id", [], decoder)
      rows |> should.equal([1, 3])
    })
  })
}

pub fn exec_invalid_sql_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let result = sqlite.exec(conn, "INVALID SQL STATEMENT")

      result |> should.be_error
    })
  })
}

pub fn exec_constraint_violation_test() {
  with_pool(fn(p) {
    sqlite.get_connection(p, fn(conn) {
      let assert Ok(_) =
        sqlite.exec(conn, "CREATE TABLE unique_test (id INTEGER PRIMARY KEY)")
      let assert Ok(_) = sqlite.exec(conn, "INSERT INTO unique_test VALUES (1)")

      // Try to insert duplicate
      let result = sqlite.exec(conn, "INSERT INTO unique_test VALUES (1)")

      result |> should.be_error
      let assert Error(QueryError(msg)) = result
      // Should contain constraint-related error
      msg |> should.not_equal("")
    })
  })
}
