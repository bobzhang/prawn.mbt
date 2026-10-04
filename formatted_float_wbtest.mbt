///|
fn float_fails(s : String) -> Bool {
  (ruby_float(s) |> ignore) catch {
    _ => return true
  }
  false
}

///|
test "ruby_float takes what Ruby's Float() takes" {
  assert_eq(ruby_float("1."), 1.0)
  assert_eq(ruby_float(".5"), 0.5)
  assert_eq(ruby_float("+.5e1"), 5.0)
  assert_eq(ruby_float("0x10"), 16.0)
  assert_eq(ruby_float(" 1_2 "), 12.0)
  assert_true(float_fails("."))
  assert_true(float_fails("oops"))
  assert_true(float_fails("1__2"))
}
