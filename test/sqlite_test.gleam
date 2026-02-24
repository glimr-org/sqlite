import gleam/dynamic/decode
import gleeunit/should
import glimr/cache/driver.{DatabaseStore} as _cache_driver
import glimr/config/database
import glimr/db/pool_connection
import glimr_sqlite/cache/cache as sqlite_cache
import glimr_sqlite/sqlite
import simplifile

const test_db = "test/fixtures/sqlite_test.db"

const config_dir = "config"

const config_file = "config/database.toml"

// ------------------------------------------------------------- Helpers

fn setup_config(toml_content: String) -> Nil {
  database.clear_cache()
  let _ = simplifile.create_directory_all(config_dir)
  let _ = simplifile.write(config_file, toml_content)
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
    pool_connection.query(
      p,
      "SELECT 1 + 1 as result",
      [],
      decode.at([0], decode.int),
    )

  result |> should.be_ok
  let assert Ok(pool_connection.QueryResult(_, rows)) = result
  rows |> should.equal([2])

  pool_connection.stop_pool(p)
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
  let result =
    pool_connection.query(p, "SELECT 42", [], decode.at([0], decode.int))

  result |> should.be_ok
  let assert Ok(pool_connection.QueryResult(_, rows)) = result
  rows |> should.equal([42])

  pool_connection.stop_pool(p)
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
    pool_connection.exec(
      p,
      "CREATE TABLE test_items (id INTEGER PRIMARY KEY, name TEXT)",
      [],
    )

  let assert Ok(_) =
    pool_connection.exec(
      p,
      "INSERT INTO test_items (name) VALUES ('item1')",
      [],
    )

  // Query the data back
  let result =
    pool_connection.query(
      p,
      "SELECT name FROM test_items WHERE id = 1",
      [],
      decode.at([0], decode.string),
    )

  result |> should.be_ok
  let assert Ok(pool_connection.QueryResult(_, rows)) = result
  rows |> should.equal(["item1"])

  pool_connection.stop_pool(p)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  Nil
}

// ------------------------------------------------------------- start_cache

pub fn start_cache_with_valid_store_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  setup_config(main_connection_toml())

  let stores = [
    DatabaseStore(name: "cache", database: "main", table: "start_cache_test"),
  ]

  let db = sqlite.start("main")

  // Create the cache table
  let assert Ok(_) =
    pool_connection.exec(
      db,
      "CREATE TABLE IF NOT EXISTS start_cache_test (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        expiration INTEGER NOT NULL
      )",
      [],
    )

  // Start the cache pool
  let cache = sqlite.start_cache(db, "cache", stores)

  // Verify it works by doing cache operations
  sqlite_cache.put(cache, "test_key", "test_value", 3600) |> should.be_ok
  sqlite_cache.get(cache, "test_key")
  |> should.be_ok
  |> should.equal("test_value")
  sqlite_cache.forget(cache, "test_key") |> should.be_ok

  pool_connection.stop_pool(db)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  Nil
}

pub fn start_cache_with_multiple_stores_test() {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  setup_config(main_connection_toml())

  let stores = [
    DatabaseStore(
      name: "primary",
      database: "main",
      table: "cache_primary_test",
    ),
    DatabaseStore(
      name: "secondary",
      database: "main",
      table: "cache_secondary_test",
    ),
  ]

  let db = sqlite.start("main")

  // Create both cache tables
  let assert Ok(_) =
    pool_connection.exec(
      db,
      "CREATE TABLE IF NOT EXISTS cache_primary_test (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        expiration INTEGER NOT NULL
      )",
      [],
    )
  let assert Ok(_) =
    pool_connection.exec(
      db,
      "CREATE TABLE IF NOT EXISTS cache_secondary_test (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        expiration INTEGER NOT NULL
      )",
      [],
    )

  // Start the secondary cache pool
  let cache = sqlite.start_cache(db, "secondary", stores)

  // Verify it works
  sqlite_cache.put(cache, "secondary_key", "secondary_value", 3600)
  |> should.be_ok
  sqlite_cache.get(cache, "secondary_key")
  |> should.be_ok
  |> should.equal("secondary_value")

  pool_connection.stop_pool(db)
  cleanup_config()
  let _ = simplifile.delete(test_db)
  Nil
}
