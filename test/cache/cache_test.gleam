import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import glimr/cache/cache
import glimr/cache/driver
import glimr/db/pool_connection
import glimr_sqlite/cache/cache as sqlite_cache
import glimr_sqlite/cache/pool as cache_pool
import glimr_sqlite/db/pool as db_pool
import simplifile

const test_db = "test/fixtures/cache_test.db"

fn setup_test_pool() -> cache_pool.Pool {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let db_config = pool_connection.SqliteConfig(test_db, 2)
  let assert Ok(db) = db_pool.start_pool(db_config)

  let store = driver.DatabaseStore("test", "main", "cache")
  let pool = cache_pool.start_pool(db, store)

  let assert Ok(_) = sqlite_cache.create_table(pool)
  pool
}

fn cleanup(pool: cache_pool.Pool) -> Nil {
  let _ = db_pool.stop_pool(cache_pool.get_db_pool(pool))
  let _ = simplifile.delete(test_db)
  Nil
}

// ------------------------------------------------------------ Basic Operations

pub fn create_table_test() {
  let pool = setup_test_pool()
  // Table already created in setup, this should be idempotent
  sqlite_cache.create_table(pool) |> should.be_ok
  cleanup(pool)
}

pub fn put_and_get_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "test_key", "test_value", 3600) |> should.be_ok
  sqlite_cache.get(pool, "test_key")
  |> should.be_ok
  |> should.equal("test_value")

  cleanup(pool)
}

pub fn get_nonexistent_key_returns_not_found_test() {
  let pool = setup_test_pool()

  case sqlite_cache.get(pool, "nonexistent") {
    Error(cache.NotFound) -> Nil
    _ -> panic as "Expected NotFound error"
  }

  cleanup(pool)
}

pub fn put_forever_test() {
  let pool = setup_test_pool()

  sqlite_cache.put_forever(pool, "permanent_key", "permanent_value")
  |> should.be_ok
  sqlite_cache.get(pool, "permanent_key")
  |> should.be_ok
  |> should.equal("permanent_value")

  cleanup(pool)
}

pub fn put_overwrites_existing_value_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "overwrite_key", "original", 3600) |> should.be_ok
  sqlite_cache.put(pool, "overwrite_key", "updated", 3600) |> should.be_ok
  sqlite_cache.get(pool, "overwrite_key")
  |> should.be_ok
  |> should.equal("updated")

  cleanup(pool)
}

pub fn forget_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "forget_key", "value", 3600) |> should.be_ok
  sqlite_cache.forget(pool, "forget_key") |> should.be_ok

  case sqlite_cache.get(pool, "forget_key") {
    Error(cache.NotFound) -> Nil
    _ -> panic as "Expected NotFound error after forget"
  }

  cleanup(pool)
}

pub fn forget_nonexistent_key_test() {
  let pool = setup_test_pool()

  // Should not error when forgetting nonexistent key
  sqlite_cache.forget(pool, "nonexistent") |> should.be_ok

  cleanup(pool)
}

pub fn has_existing_key_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "has_key", "value", 3600) |> should.be_ok
  sqlite_cache.has(pool, "has_key") |> should.equal(True)

  cleanup(pool)
}

pub fn has_nonexistent_key_test() {
  let pool = setup_test_pool()

  sqlite_cache.has(pool, "nonexistent") |> should.equal(False)

  cleanup(pool)
}

pub fn flush_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "flush1", "v1", 3600) |> should.be_ok
  sqlite_cache.put(pool, "flush2", "v2", 3600) |> should.be_ok
  sqlite_cache.put(pool, "flush3", "v3", 3600) |> should.be_ok

  sqlite_cache.flush(pool) |> should.be_ok

  sqlite_cache.has(pool, "flush1") |> should.equal(False)
  sqlite_cache.has(pool, "flush2") |> should.equal(False)
  sqlite_cache.has(pool, "flush3") |> should.equal(False)

  cleanup(pool)
}

// ------------------------------------------------------------ JSON Operations

pub fn put_json_and_get_json_test() {
  let pool = setup_test_pool()

  let data = #("hello", 42)
  let encoder = fn(d: #(String, Int)) {
    json.object([
      #("message", json.string(d.0)),
      #("count", json.int(d.1)),
    ])
  }
  let decoder = {
    use message <- decode.field("message", decode.string)
    use count <- decode.field("count", decode.int)
    decode.success(#(message, count))
  }

  sqlite_cache.put_json(pool, "json_key", data, encoder, 3600) |> should.be_ok
  sqlite_cache.get_json(pool, "json_key", decoder)
  |> should.be_ok
  |> should.equal(#("hello", 42))

  cleanup(pool)
}

pub fn put_json_forever_test() {
  let pool = setup_test_pool()

  let data = #("permanent", 99)
  let encoder = fn(d: #(String, Int)) {
    json.object([
      #("message", json.string(d.0)),
      #("count", json.int(d.1)),
    ])
  }
  let decoder = {
    use message <- decode.field("message", decode.string)
    use count <- decode.field("count", decode.int)
    decode.success(#(message, count))
  }

  sqlite_cache.put_json_forever(pool, "json_forever", data, encoder)
  |> should.be_ok
  sqlite_cache.get_json(pool, "json_forever", decoder)
  |> should.be_ok
  |> should.equal(#("permanent", 99))

  cleanup(pool)
}

pub fn get_json_with_invalid_json_test() {
  let pool = setup_test_pool()

  // Store invalid JSON
  sqlite_cache.put(pool, "invalid_json", "not json", 3600) |> should.be_ok

  let decoder = decode.string
  case sqlite_cache.get_json(pool, "invalid_json", decoder) {
    Error(cache.SerializationError(_)) -> Nil
    _ -> panic as "Expected SerializationError"
  }

  cleanup(pool)
}

// ------------------------------------------------------------ Pull Operation

pub fn pull_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "pull_key", "pull_value", 3600) |> should.be_ok

  sqlite_cache.pull(pool, "pull_key")
  |> should.be_ok
  |> should.equal("pull_value")

  // Key should be gone after pull
  sqlite_cache.has(pool, "pull_key") |> should.equal(False)

  cleanup(pool)
}

pub fn pull_nonexistent_key_test() {
  let pool = setup_test_pool()

  case sqlite_cache.pull(pool, "nonexistent") {
    Error(cache.NotFound) -> Nil
    _ -> panic as "Expected NotFound error"
  }

  cleanup(pool)
}

// ------------------------------------------------------------ Increment/Decrement

pub fn increment_existing_value_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "counter", "10", 3600) |> should.be_ok
  sqlite_cache.increment(pool, "counter", 5) |> should.be_ok |> should.equal(15)
  sqlite_cache.get(pool, "counter") |> should.be_ok |> should.equal("15")

  cleanup(pool)
}

pub fn increment_nonexistent_key_test() {
  let pool = setup_test_pool()

  sqlite_cache.increment(pool, "new_counter", 5)
  |> should.be_ok
  |> should.equal(5)
  sqlite_cache.get(pool, "new_counter") |> should.be_ok |> should.equal("5")

  cleanup(pool)
}

pub fn increment_non_numeric_value_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "not_number", "hello", 3600) |> should.be_ok

  case sqlite_cache.increment(pool, "not_number", 1) {
    Error(cache.SerializationError(_)) -> Nil
    _ -> panic as "Expected SerializationError"
  }

  cleanup(pool)
}

pub fn decrement_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "dec_counter", "10", 3600) |> should.be_ok
  sqlite_cache.decrement(pool, "dec_counter", 3)
  |> should.be_ok
  |> should.equal(7)

  cleanup(pool)
}

// ------------------------------------------------------------ Remember Operations

pub fn remember_with_cache_hit_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "remember_key", "cached_value", 3600) |> should.be_ok

  let compute_called = fn() { Ok("computed_value") }

  sqlite_cache.remember(pool, "remember_key", 3600, compute_called)
  |> should.be_ok
  |> should.equal("cached_value")

  cleanup(pool)
}

pub fn remember_with_cache_miss_test() {
  let pool = setup_test_pool()

  let compute = fn() { Ok("computed_value") }

  sqlite_cache.remember(pool, "new_key", 3600, compute)
  |> should.be_ok
  |> should.equal("computed_value")

  // Value should now be cached
  sqlite_cache.get(pool, "new_key")
  |> should.be_ok
  |> should.equal("computed_value")

  cleanup(pool)
}

pub fn remember_with_compute_failure_test() {
  let pool = setup_test_pool()

  let compute = fn() { Error("compute failed") }

  case sqlite_cache.remember(pool, "fail_key", 3600, compute) {
    Error(cache.ComputeError(_)) -> Nil
    _ -> panic as "Expected ComputeError"
  }

  cleanup(pool)
}

pub fn remember_forever_test() {
  let pool = setup_test_pool()

  let compute = fn() { Ok("forever_value") }

  sqlite_cache.remember_forever(pool, "forever_key", compute)
  |> should.be_ok
  |> should.equal("forever_value")

  sqlite_cache.get(pool, "forever_key")
  |> should.be_ok
  |> should.equal("forever_value")

  cleanup(pool)
}

pub fn remember_json_test() {
  let pool = setup_test_pool()

  let encoder = fn(n: Int) { json.int(n) }
  let decoder = decode.int
  let compute = fn() { Ok(42) }

  sqlite_cache.remember_json(
    pool,
    "json_remember",
    3600,
    decoder,
    compute,
    encoder,
  )
  |> should.be_ok
  |> should.equal(42)

  // Value should now be cached
  sqlite_cache.get_json(pool, "json_remember", decoder)
  |> should.be_ok
  |> should.equal(42)

  cleanup(pool)
}

// ------------------------------------------------------------ Cleanup Operations

pub fn cleanup_expired_test() {
  let pool = setup_test_pool()

  // Store with 0 TTL (already expired by the time we check)
  sqlite_cache.put(pool, "expired_key", "value", -1) |> should.be_ok

  sqlite_cache.cleanup_expired(pool) |> should.be_ok

  sqlite_cache.has(pool, "expired_key") |> should.equal(False)

  cleanup(pool)
}

pub fn cleanup_expired_keeps_valid_entries_test() {
  let pool = setup_test_pool()

  sqlite_cache.put(pool, "expired", "value", -1) |> should.be_ok
  sqlite_cache.put(pool, "valid", "value", 3600) |> should.be_ok
  sqlite_cache.put_forever(pool, "permanent", "value") |> should.be_ok

  sqlite_cache.cleanup_expired(pool) |> should.be_ok

  sqlite_cache.has(pool, "expired") |> should.equal(False)
  sqlite_cache.has(pool, "valid") |> should.equal(True)
  sqlite_cache.has(pool, "permanent") |> should.equal(True)

  cleanup(pool)
}
