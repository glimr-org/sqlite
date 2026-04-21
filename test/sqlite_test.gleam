import gleam/dynamic/decode
import gleeunit/should
import glimr/cache
import glimr/config
import glimr/db/db
import glimr/db/driver
import glimr_sqlite/sqlite
import simplifile

const test_db = "test/fixtures/sqlite_test.db"

const config_dir = "config"

const config_file = "config/database.toml"

// ------------------------------------------------------------- Helpers

fn setup_config(toml_content: String) -> Nil {
  driver.clear_cache()
  config.clear_cache()
  let _ = simplifile.create_directory_all(config_dir)
  let _ = simplifile.write(config_file, toml_content)
  config.load()
  Nil
}

fn cleanup_config() -> Nil {
  let _ = simplifile.delete(config_file)
  Nil
}

fn main_connection_toml() -> String {
  "[connections.main]
  driver = \"sqlite\"
  database = \"" <> test_db <> "\"
  pool_size = 2
"
}

fn multi_connection_toml() -> String {
  "[connections.main]
  driver = \"sqlite\"
  database = \"" <> test_db <> "\"
  pool_size = 2

[connections.secondary]
  driver = \"sqlite\"
  database = \"test/fixtures/sqlite_secondary.db\"
  pool_size = 1
"
}

fn test_connection_toml() -> String {
  "[connections.test]
  driver = \"sqlite\"
  database = \"" <> test_db <> "\"
  pool_size = 3
"
}

// ------------------------------------------------------------- start

pub fn start_with_valid_connection_test() {
  // Clean up any existing test db
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  setup_config(main_connection_toml())

  let p = sqlite.start("main")

  // Verify the pool works by executing a query
  let result =
    db.query(p, "SELECT 1 + 1 as result", [], decode.at([0], decode.int))

  result |> should.be_ok
  let assert Ok(db.QueryResult(_, rows)) = result
  rows |> should.equal([2])

  db.stop_pool(p)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  Nil
}

pub fn start_with_multiple_connections_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.delete("test/fixtures/sqlite_secondary.db")
  let _ = simplifile.create_directory_all("test/fixtures")

  setup_config(multi_connection_toml())

  // Start the secondary connection
  let p = sqlite.start("secondary")

  // Verify it works
  let result = db.query(p, "SELECT 42", [], decode.at([0], decode.int))

  result |> should.be_ok
  let assert Ok(db.QueryResult(_, rows)) = result
  rows |> should.equal([42])

  db.stop_pool(p)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  let _ = simplifile.delete("test/fixtures/sqlite_secondary.db")
  Nil
}

pub fn start_creates_usable_pool_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  setup_config(test_connection_toml())

  let p = sqlite.start("test")

  // Create a table and insert data
  let assert Ok(_) =
    db.exec(
      p,
      "CREATE TABLE test_items (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )

  let assert Ok(_) =
    db.exec(p, "INSERT INTO test_items (name) VALUES ('item1')", [])

  // Query the data back
  let result =
    db.query(
      p,
      "SELECT name FROM test_items WHERE id = 1",
      [],
      decode.at([0], decode.string),
    )

  result |> should.be_ok
  let assert Ok(db.QueryResult(_, rows)) = result
  rows |> should.equal(["item1"])

  db.stop_pool(p)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  Nil
}

// ------------------------------------------------------------- start_cache

pub fn start_cache_with_valid_store_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  setup_config(main_connection_toml())

  let db = sqlite.start("main")

  // Create the cache table
  let assert Ok(_) =
    db.exec(
      db,
      "CREATE TABLE IF NOT EXISTS start_cache_test (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        expiration INTEGER NOT NULL
      )",
      [],
    )

  // Start the cache pool
  let pool = cache.database_start_with_table(db, "start_cache_test")

  // Verify it works by doing cache operations
  cache.put(pool, "test_key", "test_value", 3600) |> should.be_ok
  cache.get(pool, "test_key")
  |> should.be_ok
  |> should.equal("test_value")
  cache.forget(pool, "test_key") |> should.be_ok

  db.stop_pool(db)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  Nil
}

pub fn start_cache_with_multiple_stores_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  setup_config(main_connection_toml())

  let db = sqlite.start("main")

  // Create both cache tables
  let assert Ok(_) =
    db.exec(
      db,
      "CREATE TABLE IF NOT EXISTS cache_primary_test (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        expiration INTEGER NOT NULL
      )",
      [],
    )
  let assert Ok(_) =
    db.exec(
      db,
      "CREATE TABLE IF NOT EXISTS cache_secondary_test (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        expiration INTEGER NOT NULL
      )",
      [],
    )

  // Start the secondary cache pool
  let pool = cache.database_start_with_table(db, "cache_secondary_test")

  // Verify it works
  cache.put(pool, "secondary_key", "secondary_value", 3600)
  |> should.be_ok
  cache.get(pool, "secondary_key")
  |> should.be_ok
  |> should.equal("secondary_value")

  db.stop_pool(db)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  Nil
}
