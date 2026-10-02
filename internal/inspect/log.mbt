///|
/// How two JSON observations differ (numbers within `tol`), if they do.
fn json_difference(a : Json, b : Json, tol : Double) -> String? {
  match (a, b) {
    (Number(x, ..), Number(y, ..)) =>
      if near(x, y, tol) {
        None
      } else {
        Some("\{x} vs \{y}")
      }
    (Array(xs), Array(ys)) => {
      if xs.length() != ys.length() {
        return Some("\{a.stringify()} vs \{b.stringify()}")
      }
      for i, x in xs {
        if json_difference(x, ys[i], tol) is Some(_) {
          return Some("\{a.stringify()} vs \{b.stringify()}")
        }
      }
      None
    }
    (Object(xs), Object(ys)) => {
      if xs.length() != ys.length() {
        return Some("\{a.stringify()} vs \{b.stringify()}")
      }
      for k, x in xs {
        match ys.get(k) {
          Some(y) if json_difference(x, y, tol) is None => ()
          _ => return Some("\{a.stringify()} vs \{b.stringify()}")
        }
      }
      None
    }
    _ =>
      if a == b {
        None
      } else {
        Some("\{a.stringify()} vs \{b.stringify()}")
      }
  }
}

///|
/// The differences between two observation logs (docs/op-scripts.md), one
/// JSON object per line: entry by entry, numbers within `tol` (Ruby's and
/// MoonBit's floating-point operation order may differ in the last bits).
pub fn compare_logs(
  expected : String,
  actual : String,
  tol? : Double = 1.0e-6,
) -> Array[String] raise {
  let parse = fn(text : String) raise {
    let out : Array[Json] = []
    for line in text.split("\n") {
      if !line.is_empty() {
        out.push(@json.parse(line.to_owned()))
      }
    }
    out
  }
  let a = parse(expected)
  let b = parse(actual)
  let out : Array[String] = []
  for i in 0..<min(a.length(), b.length()) {
    match json_difference(a[i], b[i], tol) {
      Some(d) => out.push("log entry \{i + 1}: \{d}")
      None => ()
    }
  }
  if a.length() != b.length() {
    out.push("log: \{a.length()} entries vs \{b.length()}")
  }
  out
}
