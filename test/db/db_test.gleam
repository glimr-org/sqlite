import gleam/dynamic/decode
import gleeunit/should
import glimr/db/db.{ConnectionError, QueryError}
import glimr_sqlite/sqlite
import simplifile

const test_db = "test/fixtures/db_test.db"

fn with_pool(f: fn(db.DbPool) -> a) -> a {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 2)
  let core_pool = sqlite.start_from_config(config)

  // Create test table
  let _ = {
    use conn <- db.get_connection(core_pool)
    db.exec_with(
      conn,
      "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)",
      [],
    )
  }

  let result = f(core_pool)

  db.stop_pool(core_pool)
  let _ = simplifile.delete(test_db)
  result
}

pub fn transaction_commits_on_success_test() {
  with_pool(fn(p) {
    // Insert in transaction
    let result =
      db.transaction(p, 0, fn(conn) {
        case db.exec_with(conn, "INSERT INTO accounts VALUES (1, 100)", []) {
          Ok(_) -> Ok(Nil)
          Error(e) -> Error(e)
        }
      })

    result |> should.be_ok

    // Verify data persisted
    use conn <- db.get_connection(p)
    let decoder = decode.at([1], decode.int)
    case
      db.query_with(conn, "SELECT * FROM accounts WHERE id = 1", [], decoder)
    {
      Ok(db.QueryResult(_, [balance])) -> balance |> should.equal(100)
      _ -> panic as "Expected one row"
    }
  })
}

pub fn transaction_returns_value_test() {
  with_pool(fn(p) {
    let result =
      db.transaction(p, 0, fn(conn) {
        case db.exec_with(conn, "INSERT INTO accounts VALUES (1, 50)", []) {
          Ok(_) -> {
            let decoder = decode.at([1], decode.int)
            case
              db.query_with(
                conn,
                "SELECT * FROM accounts WHERE id = 1",
                [],
                decoder,
              )
            {
              Ok(db.QueryResult(_, [balance])) -> Ok(balance * 2)
              Error(e) -> Error(e)
              _ -> Error(QueryError("No rows returned"))
            }
          }
          Error(e) -> Error(e)
        }
      })

    result |> should.be_ok
    let assert Ok(value) = result
    value |> should.equal(100)
  })
}

pub fn transaction_rolls_back_on_error_test() {
  with_pool(fn(p) {
    // First insert some data
    let _ = {
      use conn <- db.get_connection(p)
      db.exec_with(conn, "INSERT INTO accounts VALUES (1, 100)", [])
    }

    // Transaction that fails
    let result =
      db.transaction(p, 0, fn(conn) {
        case
          db.exec_with(
            conn,
            "UPDATE accounts SET balance = 200 WHERE id = 1",
            [],
          )
        {
          Ok(_) ->
            // Return error to trigger rollback
            Error(QueryError("Intentional failure"))
          Error(e) -> Error(e)
        }
      })

    result |> should.be_error

    // Verify data was rolled back
    use conn <- db.get_connection(p)
    let decoder = decode.at([1], decode.int)
    case
      db.query_with(conn, "SELECT * FROM accounts WHERE id = 1", [], decoder)
    {
      Ok(db.QueryResult(_, [balance])) -> balance |> should.equal(100)
      _ -> panic as "Expected one row"
    }
  })
}

pub fn transaction_rolls_back_on_query_error_test() {
  with_pool(fn(p) {
    let _ = {
      use conn <- db.get_connection(p)
      db.exec_with(conn, "INSERT INTO accounts VALUES (1, 100)", [])
    }

    let result =
      db.transaction(p, 0, fn(conn) {
        case
          db.exec_with(
            conn,
            "UPDATE accounts SET balance = 500 WHERE id = 1",
            [],
          )
        {
          Ok(_) ->
            // This will fail - table doesn't exist
            db.exec_with(conn, "INSERT INTO nonexistent_table VALUES (1)", [])
            |> result_to_nil
          Error(e) -> Error(e)
        }
      })

    result |> should.be_error

    // Verify rollback
    use conn <- db.get_connection(p)
    let decoder = decode.at([1], decode.int)
    case
      db.query_with(conn, "SELECT * FROM accounts WHERE id = 1", [], decoder)
    {
      Ok(db.QueryResult(_, [balance])) -> balance |> should.equal(100)
      _ -> panic as "Expected one row"
    }
  })
}

pub fn transaction_negative_retries_returns_error_test() {
  with_pool(fn(p) {
    let result = db.transaction(p, -1, fn(_conn) { Ok(Nil) })

    result |> should.be_error
    let assert Error(ConnectionError(msg)) = result
    msg |> should.equal("Transaction retries cannot be negative")
  })
}

pub fn transaction_multiple_operations_test() {
  with_pool(fn(p) {
    let result =
      db.transaction(p, 0, fn(conn) {
        case db.exec_with(conn, "INSERT INTO accounts VALUES (1, 100)", []) {
          Ok(_) ->
            case
              db.exec_with(conn, "INSERT INTO accounts VALUES (2, 200)", [])
            {
              Ok(_) ->
                case
                  db.exec_with(
                    conn,
                    "UPDATE accounts SET balance = balance + 50 WHERE id = 1",
                    [],
                  )
                {
                  Ok(_) -> Ok(Nil)
                  Error(e) -> Error(e)
                }
              Error(e) -> Error(e)
            }
          Error(e) -> Error(e)
        }
      })

    result |> should.be_ok

    use conn <- db.get_connection(p)
    let decoder = {
      use id <- decode.field(0, decode.int)
      use balance <- decode.field(1, decode.int)
      decode.success(#(id, balance))
    }
    case
      db.query_with(conn, "SELECT * FROM accounts ORDER BY id", [], decoder)
    {
      Ok(db.QueryResult(_, rows)) ->
        rows |> should.equal([#(1, 150), #(2, 200)])
      _ -> panic as "Expected two rows"
    }
  })
}

fn result_to_nil(result: Result(Int, db.DbError)) -> Result(Nil, db.DbError) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}
