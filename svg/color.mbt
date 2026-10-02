///|
// prawn-svg's colour parser: a paint is a list of whitespace-separated
// candidates (`url(#gradient) red`), each a hex colour, an HTML colour
// name, `rgb(...)`, `device-cmyk(...)` or a `url(...)`; black is appended
// unless a URL was given. The first candidate that can be used wins.

///|
priv enum ColorCandidate {
  Rgb(Int)
  Url(String)
}

///|
fn hex_digit(c : UInt16) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0')
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a' + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A' + 10)
  } else {
    None
  }
}

///|
/// The values of `name(v1, v2, ...)` (`name` case-insensitive), each
/// `-?[0-9.]+%?` between optional spaces, when `token` is exactly that.
fn function_values(
  token : String,
  name : String,
  count : Int,
) -> Array[String]? {
  let lower = downcase(token)
  guard lower.has_prefix(name + "(") && lower.has_suffix(")") else {
    return None
  }
  let inner = token.unsafe_substring(
    start=name.length() + 1,
    end=token.length() - 1,
  )
  let parts = inner.split(",").map(p => p.to_owned()).collect()
  guard parts.length() == count else { return None }
  let values = []
  for part in parts {
    // spaces only (prawn-svg's pattern has literal spaces)
    let mut a = 0
    let mut b = part.length()
    while a < b && part[a] == ' ' {
      a += 1
    }
    while b > a && part[b - 1] == ' ' {
      b -= 1
    }
    let v = part.unsafe_substring(start=a, end=b)
    let mut i = 0
    if i < v.length() && v[i] == '-' {
      i += 1
    }
    let digits_start = i
    while i < v.length() && ((v[i] >= '0' && v[i] <= '9') || v[i] == '.') {
      i += 1
    }
    if i == digits_start {
      return None
    }
    if i < v.length() && v[i] == '%' {
      i += 1
    }
    if i != v.length() {
      return None
    }
    values.push(v)
  }
  Some(values)
}

///|
fn clamp_int(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// Ruby's `Float#round` (half away from zero).
fn round_half_away(v : Double) -> Int {
  if v >= 0.0 {
    (v + 0.5).floor().to_int()
  } else {
    -(-v + 0.5).floor().to_int()
  }
}

///|
fn parse_candidate(token : String) -> ColorCandidate? {
  let n = token.length()
  if n == 4 && token[0] == '#' {
    match (hex_digit(token[1]), hex_digit(token[2]), hex_digit(token[3])) {
      (Some(r), Some(g), Some(b)) =>
        return Some(Rgb(((r * 17) << 16) | ((g * 17) << 8) | (b * 17)))
      _ => ()
    }
  }
  if n == 7 && token[0] == '#' {
    let mut value = 0
    let mut ok = true
    for i in 1..<7 {
      match hex_digit(token[i]) {
        Some(d) => value = value * 16 + d
        None => ok = false
      }
    }
    if ok {
      return Some(Rgb(value))
    }
  }
  match html_colors.get(downcase(token)) {
    Some(v) => return Some(Rgb(v))
    None => ()
  }
  match function_values(token, "rgb", 3) {
    Some(values) => {
      let mut rgb = 0
      for v in values {
        let mut f = ruby_to_f(v)
        if v.has_suffix("%") {
          f *= 2.55
        }
        rgb = (rgb << 8) | clamp_int(round_half_away(f), 0, 255)
      }
      return Some(Rgb(rgb))
    }
    None => ()
  }
  match function_values(token, "device-cmyk", 4) {
    Some(values) => {
      let cmyk = values.map(v => {
        let mut f = ruby_to_f(v)
        if !v.has_suffix("%") {
          f *= 100.0
        }
        @cmp.maximum(0.0, @cmp.minimum(100.0, f)) / 100.0
      })
      // shown in RGB (this renderer draws in RGB only)
      let k = cmyk[3]
      let channel = fn(c : Double) {
        clamp_int(round_half_away(255.0 * (1.0 - c) * (1.0 - k)), 0, 255)
      }
      return Some(
        Rgb(
          (channel(cmyk[0]) << 16) | (channel(cmyk[1]) << 8) | channel(cmyk[2]),
        ),
      )
    }
    None => ()
  }
  let lower = downcase(token)
  if lower.has_prefix("url(") &&
    lower.has_suffix(")") &&
    !token.unsafe_substring(start=4, end=n - 1).contains(")") {
    return Some(Url(token.unsafe_substring(start=4, end=n - 1)))
  }
  None
}

///|
/// The candidates of a paint value, in order, with black appended when no
/// URL was given (prawn-svg's `Color.parse`).
fn parse_color(value : String) -> Array[ColorCandidate] {
  let s = strip(value)
  let out = []
  let mut url = false
  let n = s.length()
  let mut i = 0
  while i < n {
    // a token: non-space, non-paren characters, then one `(...)`
    while i < n && (is_ws(s[i]) || s[i] == '(') {
      i += 1
    }
    if i >= n {
      break
    }
    let start = i
    while i < n && !is_ws(s[i]) && s[i] != '(' {
      i += 1
    }
    if i < n && s[i] == '(' {
      match find_from(s, ")", i) {
        Some(close) => i = close + 1
        None => ()
      }
    }
    let token = s.unsafe_substring(start~, end=i)
    let lower = downcase(token)
    if lower.has_prefix("url(") && lower.has_suffix(")") {
      url = true
    }
    match parse_candidate(token) {
      Some(c) => out.push(c)
      None => ()
    }
  }
  if !url {
    out.push(Rgb(0))
  }
  out
}

///|
/// The first plain colour among a value's candidates (prawn-svg's
/// `css_color_to_prawn_color`).
fn css_color(value : String?) -> Int? {
  for candidate in parse_color(value.unwrap_or("")) {
    if candidate is Rgb(v) {
      return Some(v)
    }
  }
  None
}

///|
fn color_of(rgb : Int) -> @pagelayout.Color {
  @pagelayout.Color::rgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
}
