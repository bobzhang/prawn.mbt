///|
// Numbers and lengths as prawn-svg reads them, which is mostly Ruby's
// `String#to_f`: the longest numeric prefix, 0 when there is none.

///|
/// Ruby's `String#to_f`: leading whitespace, a sign, digits (with `_`
/// between them), a fraction and an exponent, as far as they parse; 0.0
/// when no digits start the string.
pub fn ruby_to_f(s : String) -> Double {
  let n = s.length()
  let mut i = 0
  while i < n &&
        (
          s[i] == ' ' ||
          s[i] == '\t' ||
          s[i] == '\n' ||
          s[i] == '\r' ||
          s[i] == '\u{0B}' ||
          s[i] == '\u{0C}'
        ) {
    i += 1
  }
  let start = i
  if i < n && (s[i] == '+' || s[i] == '-') {
    i += 1
  }
  let digits = StringBuilder()
  if start < i && s[start] == '-' {
    digits.write_char('-')
  }
  let mut any = false
  let is_digit = fn(k : Int) { k < n && s[k] >= '0' && s[k] <= '9' }
  while is_digit(i) || (i < n && s[i] == '_' && any && is_digit(i + 1)) {
    if s[i] != '_' {
      digits.write_char(s[i].unsafe_to_char())
      any = true
    }
    i += 1
  }
  if i < n && s[i] == '.' && is_digit(i + 1) {
    digits.write_char('.')
    i += 1
    while is_digit(i) || (i < n && s[i] == '_' && is_digit(i + 1)) {
      if s[i] != '_' {
        digits.write_char(s[i].unsafe_to_char())
      }
      i += 1
    }
    any = true
  }
  if !any {
    return 0.0
  }
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    let mut j = i + 1
    let exp = StringBuilder()
    if j < n && (s[j] == '+' || s[j] == '-') {
      exp.write_char(s[j].unsafe_to_char())
      j += 1
    }
    if is_digit(j) {
      while is_digit(j) {
        exp.write_char(s[j].unsafe_to_char())
        j += 1
      }
      digits.write_char('e')
      digits.write_string(exp.to_string())
    }
  }
  @string.parse_double(digits.to_string()) catch {
    _ => 0.0
  }
}

///|
fn is_ws(c : UInt16) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0C}'
}

///|
/// Split on prawn-svg's `COMMA_WSP_REGEXP` (`\s+,?\s*|,\s*`) the way
/// Ruby's `String#split` does: a leading empty field is kept, trailing ones
/// are dropped.
pub fn split_comma_wsp(s : StringView) -> Array[String] {
  let out = []
  let n = s.length()
  let mut field = 0
  let mut i = 0
  while i < n {
    let c = s[i]
    if is_ws(c) || c == ',' {
      let sep_start = i
      if is_ws(c) {
        while i < n && is_ws(s[i]) {
          i += 1
        }
        if i < n && s[i] == ',' {
          i += 1
        }
        while i < n && is_ws(s[i]) {
          i += 1
        }
      } else {
        i += 1
        while i < n && is_ws(s[i]) {
          i += 1
        }
      }
      out.push(s[field:sep_start].to_owned())
      field = i
    } else {
      i += 1
    }
  }
  out.push(s[field:n].to_owned())
  while out.length() > 0 && out[out.length() - 1] == "" {
    ignore(out.pop())
  }
  out
}

///|
/// prawn-svg's `Measurement.to_pixels`: `em`, `ex`, `pc`, `cm`, `mm` and
/// `in` convert (a unit must follow a digit), a percentage is of
/// `axis_length`, anything else is its number (`px` and `pt` alike).
pub fn to_pixels(
  value : String,
  axis_length : Double,
  font_size? : Double = 16.0,
) -> Double {
  let n = value.length()
  let unit_after_digit = fn(unit : String) {
    value.has_suffix(unit) &&
    n > unit.length() &&
    value[n - unit.length() - 1] >= '0' &&
    value[n - unit.length() - 1] <= '9'
  }
  let v = ruby_to_f(value)
  if unit_after_digit("em") {
    v * font_size
  } else if unit_after_digit("ex") {
    v * (font_size / 2.0)
  } else if unit_after_digit("pc") {
    v * 15.0
  } else if unit_after_digit("cm") {
    v * 72.0 / 2.54
  } else if unit_after_digit("mm") {
    v * 72.0 / 25.4
  } else if unit_after_digit("in") {
    v * 72.0
  } else if value.has_suffix("%") {
    v * axis_length / 100.0
  } else {
    v
  }
}

///|
/// The index of `pattern` in `s` at or after `from`.
fn find_from(s : String, pattern : String, from : Int) -> Int? {
  if from > s.length() {
    return None
  }
  s[from:].find(pattern).map(i => i + from)
}

///|
/// Trim ASCII whitespace from both ends (Ruby's `strip`).
fn strip(s : StringView) -> String {
  let mut a = 0
  let mut b = s.length()
  while a < b && (is_ws(s[a]) || s[a] == '\u{00}' || s[a] == '\u{0B}') {
    a += 1
  }
  while b > a &&
        (is_ws(s[b - 1]) || s[b - 1] == '\u{00}' || s[b - 1] == '\u{0B}') {
    b -= 1
  }
  s[a:b].to_owned()
}

///|
/// ASCII lower case.
fn downcase(s : StringView) -> String {
  let sb = StringBuilder()
  for c in s {
    if c >= 'A' && c <= 'Z' {
      sb.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}
