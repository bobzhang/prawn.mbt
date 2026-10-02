///|
/// The comparison's tolerances (PLAN.md §3).
pub(all) struct Tolerance {
  /// Positions and lengths in page space, in points.
  position : Double
  /// Colour components and alpha.
  colour : Double
}

///|
pub let default_tolerance : Tolerance = { position: 0.01, colour: 1.0e-5, }

///|
/// At most this many differences are reported per page and kind.
let report_limit = 5

///|
fn near(a : Double, b : Double, tol : Double) -> Bool {
  (a - b).abs() <= tol
}

///|
fn fmt(x : Double) -> String {
  let r = (x * 1000.0).round() / 1000.0
  r.to_string()
}

///|
fn colours_near(a : Array[Double], b : Array[Double], tol : Double) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i, x in a {
    if !near(x, b[i], tol) {
      return false
    }
  }
  true
}

///|
fn glyph_text(g : Glyph) -> String {
  "\{g.text.escape()} \{g.font} \{fmt(g.size)} at (\{fmt(g.x)}, \{fmt(g.y)})"
}

///|
/// How glyph `a` (expected) and `b` (actual) differ, if they do.
fn glyph_difference(a : Glyph, b : Glyph, tol : Tolerance) -> String? {
  if a.text != b.text || a.font != b.font {
    return Some("\{glyph_text(a)} vs \{glyph_text(b)}")
  }
  if !near(a.size, b.size, tol.position) {
    return Some("\{glyph_text(a)}: size \{fmt(b.size)}")
  }
  if !near(a.x, b.x, tol.position) || !near(a.y, b.y, tol.position) {
    return Some(
      "\{glyph_text(a)}: at (\{fmt(b.x)}, \{fmt(b.y)}), off by (\{fmt(b.x - a.x)}, \{fmt(b.y - a.y)})",
    )
  }
  if a.mode != b.mode {
    return Some("\{glyph_text(a)}: render mode \{a.mode} vs \{b.mode}")
  }
  if a.space != b.space ||
    !colours_near(a.colour, b.colour, tol.colour) ||
    !near(a.alpha, b.alpha, tol.colour) {
    return Some(
      "\{glyph_text(a)}: colour \{a.space} \{a.colour.to_json().stringify()} alpha \{a.alpha} vs \{b.space} \{b.colour.to_json().stringify()} alpha \{b.alpha}",
    )
  }
  None
}

///|
/// Compares JSON with numbers within `tol`, colour numbers (under a key
/// mentioning colour or alpha) within `ctol`; the path to the first
/// difference.
fn json_difference(
  a : Json,
  b : Json,
  tol : Double,
  ctol : Double,
  path : String,
) -> String? {
  match (a, b) {
    (Number(x, ..), Number(y, ..)) => {
      let limit = if path.contains("colour") ||
        path.contains("alpha") ||
        path.contains("fill") ||
        path.contains("stroke") {
        ctol
      } else {
        tol
      }
      if near(x, y, limit) {
        None
      } else {
        Some("\{path}: \{x} vs \{y}")
      }
    }
    (Array(xs), Array(ys)) => {
      if xs.length() != ys.length() {
        return Some("\{path}: \{xs.length()} items vs \{ys.length()}")
      }
      for i, x in xs {
        match json_difference(x, ys[i], tol, ctol, "\{path}[\{i}]") {
          Some(d) => return Some(d)
          None => ()
        }
      }
      None
    }
    (Object(xs), Object(ys)) => {
      for k, x in xs {
        guard ys.get(k) is Some(y) else { return Some("\{path}.\{k}: missing") }
        match json_difference(x, y, tol, ctol, "\{path}.\{k}") {
          Some(d) => return Some(d)
          None => ()
        }
      }
      for k, _ in ys {
        if !xs.contains(k) {
          return Some("\{path}.\{k}: unexpected")
        }
      }
      None
    }
    _ =>
      if a == b {
        None
      } else {
        Some("\{path}: \{a.stringify()} vs \{b.stringify()}")
      }
  }
}

///|
/// The differences between `expected` and `actual` (empty when they agree
/// within `tol`): page count and sizes; per page, the glyph sequence (text,
/// font, size, origin, render mode, colour, alpha) and the marks in paint
/// order (kind, geometry, style).
pub fn compare(
  expected : Array[PageView],
  actual : Array[PageView],
  tol? : Tolerance = default_tolerance,
) -> Array[String] {
  let out : Array[String] = []
  if expected.length() != actual.length() {
    out.push("pages: \{expected.length()} vs \{actual.length()}")
  }
  let n = if expected.length() < actual.length() {
    expected.length()
  } else {
    actual.length()
  }
  for p in 0..<n {
    let a = expected[p]
    let b = actual[p]
    let page = "page \{p + 1}"
    if !near(a.width, b.width, tol.position) ||
      !near(a.height, b.height, tol.position) ||
      a.rotate != b.rotate {
      out.push(
        "\{page}: size \{fmt(a.width)}x\{fmt(a.height)} rotate \{a.rotate} vs \{fmt(b.width)}x\{fmt(b.height)} rotate \{b.rotate}",
      )
    }
    let mut reported = 0
    if a.glyphs.length() != b.glyphs.length() {
      out.push(
        "\{page}: \{a.glyphs.length()} glyphs vs \{b.glyphs.length()} (\{text_of(a.glyphs).escape()} vs \{text_of(b.glyphs).escape()})",
      )
      reported = reported + 1
    }
    for i in 0..<min(a.glyphs.length(), b.glyphs.length()) {
      if reported >= report_limit {
        break
      }
      match glyph_difference(a.glyphs[i], b.glyphs[i], tol) {
        Some(d) => {
          out.push("\{page} glyph \{i}: \{d}")
          reported = reported + 1
        }
        None => ()
      }
    }
    reported = 0
    if a.marks.length() != b.marks.length() {
      out.push(
        "\{page}: \{a.marks.length()} marks vs \{b.marks.length()} (\{kinds(a.marks)} vs \{kinds(b.marks)})",
      )
      reported = reported + 1
    }
    for i in 0..<min(a.marks.length(), b.marks.length()) {
      if reported >= report_limit {
        break
      }
      let x = a.marks[i]
      let y = b.marks[i]
      let d = if x.kind != y.kind {
        Some("\{x.kind} vs \{y.kind}")
      } else {
        match
          json_difference(x.shape, y.shape, tol.position, tol.position, "shape") {
          Some(d) => Some(d)
          None =>
            json_difference(x.style, y.style, tol.position, tol.colour, "style")
        }
      }
      match d {
        Some(d) => {
          out.push("\{page} mark \{i} (\{x.kind}): \{d}")
          reported = reported + 1
        }
        None => ()
      }
    }
  }
  out
}

///|
fn min(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn text_of(glyphs : Array[Glyph]) -> String {
  let sb = StringBuilder()
  for g in glyphs {
    sb.write_string(g.text)
  }
  let s = sb.to_string()
  if s.length() > 60 {
    s[:60].to_owned() + "…"
  } else {
    s
  }
}

///|
fn kinds(marks : Array[Mark]) -> String {
  let counts : Map[String, Int] = Map([])
  for m in marks {
    counts[m.kind] = counts.get(m.kind).unwrap_or(0) + 1
  }
  counts.to_array().map(kv => "\{kv.1} \{kv.0}").join(", ")
}
