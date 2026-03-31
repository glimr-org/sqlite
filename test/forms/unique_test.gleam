import gleeunit/should
import glimr/db/db
import glimr/forms/validator
import glimr_sqlite/sqlite
import simplifile

const test_db = "test/fixtures/unique_test.db"

fn with_pool(f: fn(db.DbPool) -> a) -> a {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let config = db.SqliteConfig(test_db, 2)
  let pool = sqlite.start_from_config(config)

  let _ = {
    use conn <- db.get_connection(pool)
    let assert Ok(_) =
      db.exec_with(
        conn,
        "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, api_key TEXT)",
        [],
      )
    let assert Ok(_) =
      db.exec_with(
        conn,
        "INSERT INTO users (email, api_key) VALUES ('admin@example.com', 'secret-KEY-123')",
        [],
      )
  }

  let result = f(pool)

  db.stop_pool(pool)
  let _ = simplifile.delete(test_db)
  result
}

fn form(field: String, value: String) -> validator.FormData {
  validator.FormData(
    get: fn(key) {
      case key == field {
        True -> value
        False -> ""
      }
    },
    get_file: fn(_) { panic as "not used" },
    get_file_result: fn(_) { panic as "not used" },
  )
}

const ctx = Nil

// ------------------------------------------------------------- Unique (case-insensitive)

pub fn unique_passes_when_value_not_in_db_test() {
  with_pool(fn(pool) {
    let data = form("email", "new@example.com")

    validator.start(
      [validator.for("email", [validator.Unique(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_ok
  })
}

pub fn unique_fails_when_exact_match_exists_test() {
  with_pool(fn(pool) {
    let data = form("email", "admin@example.com")

    validator.start(
      [validator.for("email", [validator.Unique(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_error
  })
}

pub fn unique_fails_when_different_case_exists_test() {
  with_pool(fn(pool) {
    let data = form("email", "Admin@Example.COM")

    validator.start(
      [validator.for("email", [validator.Unique(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_error
  })
}

pub fn unique_fails_when_uppercase_exists_test() {
  with_pool(fn(pool) {
    let data = form("email", "ADMIN@EXAMPLE.COM")

    validator.start(
      [validator.for("email", [validator.Unique(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_error
  })
}

pub fn unique_passes_for_empty_value_test() {
  with_pool(fn(pool) {
    let data = form("email", "")

    validator.start(
      [validator.for("email", [validator.Unique(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_ok
  })
}

// ------------------------------------------------------------- UniqueSensitive (case-sensitive)

pub fn unique_sensitive_passes_when_value_not_in_db_test() {
  with_pool(fn(pool) {
    let data = form("api_key", "different-key")

    validator.start(
      [validator.for("api_key", [validator.UniqueSensitive(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_ok
  })
}

pub fn unique_sensitive_fails_when_exact_match_exists_test() {
  with_pool(fn(pool) {
    let data = form("api_key", "secret-KEY-123")

    validator.start(
      [validator.for("api_key", [validator.UniqueSensitive(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_error
  })
}

pub fn unique_sensitive_passes_when_different_case_test() {
  with_pool(fn(pool) {
    let data = form("api_key", "SECRET-key-123")

    validator.start(
      [validator.for("api_key", [validator.UniqueSensitive(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_ok
  })
}

pub fn unique_sensitive_passes_for_empty_value_test() {
  with_pool(fn(pool) {
    let data = form("api_key", "")

    validator.start(
      [validator.for("api_key", [validator.UniqueSensitive(pool, "users")])],
      data,
      ctx,
    )
    |> should.be_ok
  })
}
