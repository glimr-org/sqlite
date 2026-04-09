import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import glimr/cache/cache
import glimr/cache/database as cache_database
import glimr/db/db
import glimr_sqlite/sqlite
import simplifile

const test_db = "test/fixtures/cache_test.db"

fn setup_test_pool() -> #(cache.CachePool, db.DbPool) {
  let _ = simplifile.delete(test_db)
  let _ = simplifile.create_directory_all("test/fixtures")

  let db_config = db.SqliteConfig(test_db, 2)
  let core_pool = sqlite.start_from_config(db_config)

  let assert Ok(_) = cache_database.create_table(core_pool, "cache")
  let pool = cache_database.start_with_table(core_pool, "cache")
  #(pool, core_pool)
}

fn cleanup(db_pool: db.DbPool) -> Nil {
  let _ = db.stop_pool(db_pool)
  let _ = simplifile.delete(test_db)
  Nil
}

// ------------------------------------------------------------ Basic Operations

pub fn create_table_test() {
  let #(_pool, db) = setup_test_pool()
  // Table already created in setup, this should be idempotent
  cache_database.create_table(db, "cache") |> should.be_ok
  cleanup(db)
}

pub fn put_and_get_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "test_key", "test_value", 3600) |> should.be_ok
  cache.get(pool, "test_key")
  |> should.be_ok
  |> should.equal("test_value")

  cleanup(db)
}

pub fn get_nonexistent_key_returns_not_found_test() {
  let #(pool, db) = setup_test_pool()

  case cache.get(pool, "nonexistent") {
    Error(cache.NotFound) -> Nil
    _ -> panic as "Expected NotFound error"
  }

  cleanup(db)
}

pub fn put_forever_test() {
  let #(pool, db) = setup_test_pool()

  cache.put_forever(pool, "permanent_key", "permanent_value")
  |> should.be_ok
  cache.get(pool, "permanent_key")
  |> should.be_ok
  |> should.equal("permanent_value")

  cleanup(db)
}

pub fn put_overwrites_existing_value_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "overwrite_key", "original", 3600) |> should.be_ok
  cache.put(pool, "overwrite_key", "updated", 3600) |> should.be_ok
  cache.get(pool, "overwrite_key")
  |> should.be_ok
  |> should.equal("updated")

  cleanup(db)
}

pub fn forget_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "forget_key", "value", 3600) |> should.be_ok
  cache.forget(pool, "forget_key") |> should.be_ok

  case cache.get(pool, "forget_key") {
    Error(cache.NotFound) -> Nil
    _ -> panic as "Expected NotFound error after forget"
  }

  cleanup(db)
}

pub fn forget_nonexistent_key_test() {
  let #(pool, db) = setup_test_pool()

  // Should not error when forgetting nonexistent key
  cache.forget(pool, "nonexistent") |> should.be_ok

  cleanup(db)
}

pub fn has_existing_key_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "has_key", "value", 3600) |> should.be_ok
  cache.has(pool, "has_key") |> should.equal(True)

  cleanup(db)
}

pub fn has_nonexistent_key_test() {
  let #(pool, db) = setup_test_pool()

  cache.has(pool, "nonexistent") |> should.equal(False)

  cleanup(db)
}

pub fn flush_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "flush1", "v1", 3600) |> should.be_ok
  cache.put(pool, "flush2", "v2", 3600) |> should.be_ok
  cache.put(pool, "flush3", "v3", 3600) |> should.be_ok

  cache.flush(pool) |> should.be_ok

  cache.has(pool, "flush1") |> should.equal(False)
  cache.has(pool, "flush2") |> should.equal(False)
  cache.has(pool, "flush3") |> should.equal(False)

  cleanup(db)
}

// ------------------------------------------------------------ JSON Operations

pub fn put_json_and_get_json_test() {
  let #(pool, db) = setup_test_pool()

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

  cache.put_json(pool, "json_key", data, encoder, 3600) |> should.be_ok
  cache.get_json(pool, "json_key", decoder)
  |> should.be_ok
  |> should.equal(#("hello", 42))

  cleanup(db)
}

pub fn put_json_forever_test() {
  let #(pool, db) = setup_test_pool()

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

  cache.put_json_forever(pool, "json_forever", data, encoder)
  |> should.be_ok
  cache.get_json(pool, "json_forever", decoder)
  |> should.be_ok
  |> should.equal(#("permanent", 99))

  cleanup(db)
}

pub fn get_json_with_invalid_json_test() {
  let #(pool, db) = setup_test_pool()

  // Store invalid JSON
  cache.put(pool, "invalid_json", "not json", 3600) |> should.be_ok

  let decoder = decode.string
  case cache.get_json(pool, "invalid_json", decoder) {
    Error(cache.SerializationError(_)) -> Nil
    _ -> panic as "Expected SerializationError"
  }

  cleanup(db)
}

// ------------------------------------------------------------ Pull Operation

pub fn pull_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "pull_key", "pull_value", 3600) |> should.be_ok

  cache.pull(pool, "pull_key")
  |> should.be_ok
  |> should.equal("pull_value")

  // Key should be gone after pull
  cache.has(pool, "pull_key") |> should.equal(False)

  cleanup(db)
}

pub fn pull_nonexistent_key_test() {
  let #(pool, db) = setup_test_pool()

  case cache.pull(pool, "nonexistent") {
    Error(cache.NotFound) -> Nil
    _ -> panic as "Expected NotFound error"
  }

  cleanup(db)
}

// ------------------------------------------------------------ Increment/Decrement

pub fn increment_existing_value_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "counter", "10", 3600) |> should.be_ok
  cache.increment(pool, "counter", 5) |> should.be_ok |> should.equal(15)
  cache.get(pool, "counter") |> should.be_ok |> should.equal("15")

  cleanup(db)
}

pub fn increment_nonexistent_key_test() {
  let #(pool, db) = setup_test_pool()

  cache.increment(pool, "new_counter", 5)
  |> should.be_ok
  |> should.equal(5)
  cache.get(pool, "new_counter") |> should.be_ok |> should.equal("5")

  cleanup(db)
}

pub fn increment_non_numeric_value_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "not_number", "hello", 3600) |> should.be_ok

  case cache.increment(pool, "not_number", 1) {
    Error(cache.SerializationError(_)) -> Nil
    _ -> panic as "Expected SerializationError"
  }

  cleanup(db)
}

pub fn decrement_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "dec_counter", "10", 3600) |> should.be_ok
  cache.decrement(pool, "dec_counter", 3)
  |> should.be_ok
  |> should.equal(7)

  cleanup(db)
}

// ------------------------------------------------------------ Remember Operations

pub fn try_remember_with_cache_hit_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "remember_key", "cached_value", 3600) |> should.be_ok

  cache.try_remember(pool, "remember_key", 3600, fn() { Ok("computed_value") })
  |> should.be_ok
  |> should.equal("cached_value")

  cleanup(db)
}

pub fn try_remember_with_cache_miss_test() {
  let #(pool, db) = setup_test_pool()

  cache.try_remember(pool, "new_key", 3600, fn() { Ok("computed_value") })
  |> should.be_ok
  |> should.equal("computed_value")

  // Value should now be cached
  cache.get(pool, "new_key")
  |> should.be_ok
  |> should.equal("computed_value")

  cleanup(db)
}

pub fn try_remember_does_not_cache_errors_test() {
  let #(pool, db) = setup_test_pool()

  cache.try_remember(pool, "failing_key", 3600, fn() { Error(Nil) })
  |> should.be_error
  |> should.equal(Nil)

  // Key should still be missing
  case cache.get(pool, "failing_key") {
    Error(cache.NotFound) -> Nil
    _ -> panic as "Expected NotFound error — errors must not be cached"
  }

  cleanup(db)
}

pub fn try_remember_forever_test() {
  let #(pool, db) = setup_test_pool()

  cache.try_remember_forever(pool, "forever_key", fn() { Ok("forever_value") })
  |> should.be_ok
  |> should.equal("forever_value")

  cache.get(pool, "forever_key")
  |> should.be_ok
  |> should.equal("forever_value")

  cleanup(db)
}

pub fn try_remember_json_test() {
  let #(pool, db) = setup_test_pool()

  let encoder = fn(n: Int) { json.int(n) }
  let decoder = decode.int

  cache.try_remember_json(pool, "json_remember", 3600, decoder, encoder, fn() {
    Ok(42)
  })
  |> should.be_ok
  |> should.equal(42)

  // Value should now be cached
  cache.get_json(pool, "json_remember", decoder)
  |> should.be_ok
  |> should.equal(42)

  cleanup(db)
}

// ------------------------------------------------------------ Cleanup Operations

pub fn cleanup_expired_test() {
  let #(pool, db) = setup_test_pool()

  // Store with 0 TTL (already expired by the time we check)
  cache.put(pool, "expired_key", "value", -1) |> should.be_ok

  cache_database.cleanup_expired(db, "cache") |> should.be_ok

  cache.has(pool, "expired_key") |> should.equal(False)

  cleanup(db)
}

pub fn cleanup_expired_keeps_valid_entries_test() {
  let #(pool, db) = setup_test_pool()

  cache.put(pool, "expired", "value", -1) |> should.be_ok
  cache.put(pool, "valid", "value", 3600) |> should.be_ok
  cache.put_forever(pool, "permanent", "value") |> should.be_ok

  cache_database.cleanup_expired(db, "cache") |> should.be_ok

  cache.has(pool, "expired") |> should.equal(False)
  cache.has(pool, "valid") |> should.equal(True)
  cache.has(pool, "permanent") |> should.equal(True)

  cleanup(db)
}
