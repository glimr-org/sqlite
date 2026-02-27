import gleam/option.{None, Some}
import gleeunit/should
import glimr/db/db.{
  BlobValue, BoolValue, FloatValue, IntValue, NullValue, StringValue,
}
import glimr_sqlite/db/gen
import sqlight

pub fn int_creates_int_value_test() {
  let value = gen.int(42)
  value |> should.equal(IntValue(42))
}

pub fn int_negative_test() {
  let value = gen.int(-100)
  value |> should.equal(IntValue(-100))
}

pub fn int_zero_test() {
  let value = gen.int(0)
  value |> should.equal(IntValue(0))
}

pub fn float_creates_float_value_test() {
  let value = gen.float(3.14)
  value |> should.equal(FloatValue(3.14))
}

pub fn float_negative_test() {
  let value = gen.float(-2.5)
  value |> should.equal(FloatValue(-2.5))
}

pub fn float_zero_test() {
  let value = gen.float(0.0)
  value |> should.equal(FloatValue(0.0))
}

pub fn string_creates_string_value_test() {
  let value = gen.string("hello")
  value |> should.equal(StringValue("hello"))
}

pub fn string_empty_test() {
  let value = gen.string("")
  value |> should.equal(StringValue(""))
}

pub fn string_unicode_test() {
  let value = gen.string("hello")
  value |> should.equal(StringValue("hello"))
}

pub fn bool_true_test() {
  let value = gen.bool(True)
  value |> should.equal(BoolValue(True))
}

pub fn bool_false_test() {
  let value = gen.bool(False)
  value |> should.equal(BoolValue(False))
}

pub fn null_creates_null_value_test() {
  let value = gen.null()
  value |> should.equal(NullValue)
}

pub fn blob_creates_blob_value_test() {
  let data = <<1, 2, 3, 4, 5>>
  let value = gen.blob(data)
  value |> should.equal(BlobValue(<<1, 2, 3, 4, 5>>))
}

pub fn blob_empty_test() {
  let value = gen.blob(<<>>)
  value |> should.equal(BlobValue(<<>>))
}

pub fn nullable_some_int_test() {
  let value = gen.nullable(gen.int, Some(42))
  value |> should.equal(IntValue(42))
}

pub fn nullable_none_test() {
  let value = gen.nullable(gen.int, None)
  value |> should.equal(NullValue)
}

pub fn nullable_some_string_test() {
  let value = gen.nullable(gen.string, Some("test"))
  value |> should.equal(StringValue("test"))
}

// Test to_sqlight_value conversions

pub fn to_sqlight_value_int_test() {
  let sqlight_val = gen.to_sqlight_value(IntValue(42))
  sqlight_val |> should.equal(sqlight.int(42))
}

pub fn to_sqlight_value_float_test() {
  let sqlight_val = gen.to_sqlight_value(FloatValue(3.14))
  sqlight_val |> should.equal(sqlight.float(3.14))
}

pub fn to_sqlight_value_string_test() {
  let sqlight_val = gen.to_sqlight_value(StringValue("hello"))
  sqlight_val |> should.equal(sqlight.text("hello"))
}

pub fn to_sqlight_value_bool_true_test() {
  let sqlight_val = gen.to_sqlight_value(BoolValue(True))
  sqlight_val |> should.equal(sqlight.bool(True))
}

pub fn to_sqlight_value_bool_false_test() {
  let sqlight_val = gen.to_sqlight_value(BoolValue(False))
  sqlight_val |> should.equal(sqlight.bool(False))
}

pub fn to_sqlight_value_null_test() {
  let sqlight_val = gen.to_sqlight_value(NullValue)
  sqlight_val |> should.equal(sqlight.null())
}

pub fn to_sqlight_value_blob_test() {
  let sqlight_val = gen.to_sqlight_value(BlobValue(<<1, 2, 3>>))
  sqlight_val |> should.equal(sqlight.blob(<<1, 2, 3>>))
}
