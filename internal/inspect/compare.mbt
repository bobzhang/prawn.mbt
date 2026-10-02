///|
/// The comparison's tolerances (PLAN.md §3).
pub(all) struct Tolerance {
  /// Positions and lengths in page space, in points (glyph origins and
  /// render matrices, path points, line widths and dashes, image corners,
  /// clips).
  position : Double
  /// Colour components.
  colour : Double
  /// Values that are exact in the contract but computed in floating point
  /// (page sizes, font sizes, alpha).
  exact : Double
}

///|
pub let default_tolerance : Tolerance = {
  position: 0.01,
  colour: 1.0e-5,
  exact: 1.0e-9,
}

///|
/// At most this many differences are reported per page and kind.
let report_limit = 5

///|
fn near(a : Double, b : Double, tol : Double) -> Bool {
  (a - b).abs() <= tol
}

///|
fn all_near(a : Array[Double], b : Array[Double], tol : Double) -> Bool {
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
fn fmt(x : Double) -> String {
  let r = (x * 1000.0).round() / 1000.0
  r.to_string()
}

///|
fn fmts(xs : Array[Double]) -> String {
  "[" + xs.map(fmt).join(", ") + "]"
}

///|
fn paint_text(p : Paint?) -> String {
  match p {
    None => "none"
    Some(p) => "\{p.space} \{fmts(p.values)} alpha \{fmt(p.alpha)}"
  }
}

///|
fn paint_near(a : Paint?, b : Paint?, tol : Tolerance) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(a), Some(b)) =>
      a.space == b.space &&
      all_near(a.values, b.values, tol.colour) &&
      near(a.alpha, b.alpha, tol.exact)
    _ => false
  }
}

///|
fn rect_text(r : Rect?) -> String {
  match r {
    None => "none"
    Some(r) => "(\{fmt(r.x0)}, \{fmt(r.y0)})-(\{fmt(r.x1)}, \{fmt(r.y1)})"
  }
}

///|
fn clip_near(a : Rect?, b : Rect?, tol : Tolerance) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(a), Some(b)) =>
      all_near([a.x0, a.y0, a.x1, a.y1], [b.x0, b.y0, b.x1, b.y1], tol.position)
    _ => false
  }
}

///|
fn glyph_text(g : Glyph) -> String {
  "\{g.text.escape()} \{g.font} \{fmt(g.size)} at (\{fmt(g.x)}, \{fmt(g.y)})"
}

///|
/// How glyph `b` differs from the expected `a`, if it does.
fn glyph_difference(a : Glyph, b : Glyph, tol : Tolerance) -> String? {
  if a.text != b.text || a.font != b.font {
    return Some("\{glyph_text(a)} vs \{glyph_text(b)}")
  }
  if !near(a.size, b.size, tol.exact) {
    return Some("\{glyph_text(a)}: size \{b.size}")
  }
  if !near(a.x, b.x, tol.position) || !near(a.y, b.y, tol.position) {
    return Some(
      "\{glyph_text(a)}: at (\{fmt(b.x)}, \{fmt(b.y)}), off by (\{fmt(b.x - a.x)}, \{fmt(b.y - a.y)})",
    )
  }
  if !all_near(a.matrix, b.matrix, tol.position) {
    return Some(
      "\{glyph_text(a)}: matrix \{fmts(a.matrix)} vs \{fmts(b.matrix)}",
    )
  }
  if a.mode != b.mode {
    return Some("\{glyph_text(a)}: render mode \{a.mode} vs \{b.mode}")
  }
  if !paint_near(a.fill, b.fill, tol) {
    return Some(
      "\{glyph_text(a)}: fill \{paint_text(a.fill)} vs \{paint_text(b.fill)}",
    )
  }
  if !paint_near(a.stroke, b.stroke, tol) {
    return Some(
      "\{glyph_text(a)}: stroke \{paint_text(a.stroke)} vs \{paint_text(b.stroke)}",
    )
  }
  match (a.line_width, b.line_width) {
    (Some(x), Some(y)) if !near(x, y, tol.position) =>
      return Some("\{glyph_text(a)}: line width \{fmt(x)} vs \{fmt(y)}")
    _ => ()
  }
  if a.blend != b.blend {
    return Some("\{glyph_text(a)}: blend \{a.blend} vs \{b.blend}")
  }
  if !clip_near(a.clip, b.clip, tol) {
    return Some(
      "\{glyph_text(a)}: clip \{rect_text(a.clip)} vs \{rect_text(b.clip)}",
    )
  }
  None
}

///|
/// How mark `b` differs from the expected `a`, if it does.
fn mark_difference(a : Mark, b : Mark, tol : Tolerance) -> String? {
  if a.kind != b.kind {
    return Some("\{a.kind} vs \{b.kind}")
  }
  if a.exact != b.exact {
    return Some("\{a.exact.stringify()} vs \{b.exact.stringify()}")
  }
  if !all_near(a.points, b.points, tol.position) {
    return Some("points \{fmts(a.points)} vs \{fmts(b.points)}")
  }
  if !all_near(a.lengths, b.lengths, tol.position) {
    return Some("line width and dash \{fmts(a.lengths)} vs \{fmts(b.lengths)}")
  }
  let mut paints_differ = a.paints.length() != b.paints.length()
  for i, p in a.paints {
    if i < b.paints.length() && !paint_near(Some(p), Some(b.paints[i]), tol) {
      paints_differ = true
    }
  }
  if paints_differ {
    return Some(
      "paint \{a.paints.map(p => paint_text(Some(p))).join("; ")} vs \{b.paints.map(p => paint_text(Some(p))).join("; ")}",
    )
  }
  if a.blend != b.blend {
    return Some("blend \{a.blend} vs \{b.blend}")
  }
  if !clip_near(a.clip, b.clip, tol) {
    return Some("clip \{rect_text(a.clip)} vs \{rect_text(b.clip)}")
  }
  None
}

///|
fn overlap(a : Rect, b : Rect) -> Bool {
  a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1
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
/// Glyphs and marks that overlap must be painted in the same relative order
/// (the later one covers the earlier).
fn order_differences(
  a : PageView,
  b : PageView,
  page : String,
) -> Array[String] {
  let out : Array[String] = []
  let glyphs = min(a.glyphs.length(), b.glyphs.length())
  let marks = min(a.marks.length(), b.marks.length())
  for j in 0..<marks {
    let ma = a.marks[j]
    for i in 0..<glyphs {
      let ga = a.glyphs[i]
      if !overlap(ga.extent, ma.extent) {
        continue
      }
      let before_a = ga.order < ma.order
      let before_b = b.glyphs[i].order < b.marks[j].order
      if before_a != before_b {
        let which = if before_a { "before" } else { "after" }
        out.push(
          "\{page}: glyph \{i} (\{ga.text.escape()}) should be painted \{which} mark \{j} (\{ma.kind})",
        )
        if out.length() >= report_limit {
          return out
        }
      }
    }
  }
  for j in 0..<marks {
    for k in (j + 1)..<marks {
      if !overlap(a.marks[j].extent, a.marks[k].extent) {
        continue
      }
      let before_a = a.marks[j].order < a.marks[k].order
      let before_b = b.marks[j].order < b.marks[k].order
      if before_a != before_b {
        out.push("\{page}: marks \{j} and \{k} are painted in the other order")
        if out.length() >= report_limit {
          return out
        }
      }
    }
  }
  out
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

///|
/// The differences between `expected` and `actual` (empty when they agree
/// within `tol`): page count, sizes and rotation; per page, the glyph
/// sequence, the mark sequence, and the paint order of whatever overlaps.
pub fn compare(
  expected : Array[PageView],
  actual : Array[PageView],
  tol? : Tolerance = default_tolerance,
) -> Array[String] {
  let out : Array[String] = []
  if expected.length() != actual.length() {
    out.push("pages: \{expected.length()} vs \{actual.length()}")
  }
  for p in 0..<min(expected.length(), actual.length()) {
    let a = expected[p]
    let b = actual[p]
    let page = "page \{p + 1}"
    if !near(a.width, b.width, tol.exact) ||
      !near(a.height, b.height, tol.exact) ||
      a.rotate != b.rotate {
      out.push(
        "\{page}: size \{a.width}x\{a.height} rotate \{a.rotate} vs \{b.width}x\{b.height} rotate \{b.rotate}",
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
      match mark_difference(a.marks[i], b.marks[i], tol) {
        Some(d) => {
          out.push("\{page} mark \{i} (\{a.marks[i].kind}): \{d}")
          reported = reported + 1
        }
        None => ()
      }
    }
    out.append(order_differences(a, b, page))
  }
  out
}
