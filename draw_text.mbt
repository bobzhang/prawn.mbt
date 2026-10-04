///|
/// Prawn's `draw_text`: `text` on one line, its baseline starting at `at`
/// (a point of the bounds), in the current font at `size` (the current
/// size), in `style` ("bold", "italic", "bold_italic"; the current one by
/// default), kerned unless `kerning` is false, turned `rotate` degrees
/// about `at`. No wrapping, no page break; the cursor does not move.
pub fn Document::draw_text(
  self : Document,
  text : String,
  at~ : (Double, Double),
  size? : Double,
  style? : String,
  rotate? : Double = 0.0,
  kerning? : Bool = true,
) -> Unit raise {
  let base = self.style(size?)
  let base = match style {
    None | Some("normal") => base
    Some("bold") => { ..base, bold: true, }
    Some("italic") => { ..base, italic: true, }
    Some("bold_italic") => { ..base, bold: true, italic: true, }
    Some(other) => raise ArgumentError("style \{other}")
  }
  // the whole string is encoded first (Prawn's `normalize_encoding`)
  self.check(text, base, None)
  let draw = () => {
    let face = self.face_of(base)
    // Prawn's `draw_text!`: text beyond ASCII in a built-in font is warned
    // about, once
    if !self.dry_run &&
      !self.m17n_warned &&
      face.standard &&
      text.iter().any(c => c.to_int() > 0x7F) {
      self.m17n_warned = true
      (self.warn)(m17n_warning)
    }
    let scale = base.size / 1000.0
    let codes = text.iter().map(c => c.to_int()).to_array()
    let advances = codes.mapi((i, code) => {
      let kern = if kerning && i + 1 < codes.length() {
        face.kerning(code, codes[i + 1])
      } else {
        0.0
      }
      (face.drawn_width(code) + kern) * scale
    })
    // on the page: Prawn's `map_to_absolute`
    let b = self.bounds()
    let x = b.absolute_left + at.0
    let y = b.absolute_top - b.height + at.1
    let (bold, italic) = base.face_style()
    let font = self.model.add_font({ family: base.family, bold, italic, })
    self.page().items.push(
      Text({
        font,
        size_pt: base.size,
        x_pt: x,
        baseline_pt: self.page_h() - y,
        text,
        advances_pt: advances,
        color: self.gs().fill,
      }),
    )
  }
  if rotate == 0.0 {
    draw()
  } else {
    // Prawn turns the text matrix about the point: on the page, the same
    // as drawing it under that rotation
    self.rotate(rotate, origin=at, () => draw())
  }
}

///|
/// Prawn's `stroke_axis`: dashed axes from `at` (a point of the bounds,
/// by default their origin), `width` and `height` long (to the bounds' edge
/// by default) and `negative_axes_length` back, in `color`, with a dot and
/// a label every `step_length` points.
pub fn Document::stroke_axis(
  self : Document,
  at? : (Double, Double) = (0.0, 0.0),
  width? : Double,
  height? : Double,
  step_length? : Double = 100.0,
  negative_axes_length? : Double = 20.0,
  color? : Color = Color::rgb(0, 0, 0),
) -> Unit raise {
  let b = self.bounds()
  let width = width.unwrap_or(b.width - at.0)
  let height = height.unwrap_or(b.height - at.1)
  self.save_graphics_state(() => {
    self.set_fill_color(color)
    self.set_stroke_color(color)
    self.dash([1.0], space=4.0)
    self.horizontal_line(at.0 - negative_axes_length, at.0 + width, at=at.1)
    self.stroke()
    self.vertical_line(at.1 - negative_axes_length, at.1 + height, at=at.0)
    self.stroke()
    self.undash()
    self.circle(at, 1.0)
    self.fill()
    // Ruby's `Range#step` refuses a step that goes nowhere, the axes drawn
    if step_length <= 0.0 {
      raise ArgumentError(
        "step can't be \{if step_length == 0.0 { "0" } else { "negative" }}",
      )
    }
    // Ruby's `(step..width).step(step)`: every step up to the end, each
    // labelled as Ruby prints it
    // a range with a fraction anywhere is one of Floats, which Ruby prints
    // with one (`51.0`)
    let label = fn(point : Double, to : Double) {
      if [step_length, to].iter().any(x => x != x.floor()) {
        ruby_float_string(point)
      } else {
        ruby_number(point)
      }
    }
    for point in ruby_steps(step_length, width, step_length) {
      self.circle((at.0 + point, at.1), 1.0)
      self.fill()
      self.draw_text(
        label(point, width),
        at=(at.0 + point - 5.0, at.1 - 10.0),
        size=7.0,
      )
    }
    for point in ruby_steps(step_length, height, step_length) {
      self.circle((at.0, at.1 + point), 1.0)
      self.fill()
      self.draw_text(
        label(point, height),
        at=(at.0 - 17.0, at.1 + point - 2.0),
        size=7.0,
      )
    }
  })
}

///|
/// A number as Ruby prints a whole one: without a fraction.
pub fn ruby_number(x : Double) -> String {
  if x == x.floor() && x.abs() < 1.0e15 {
    x.to_int64().to_string()
  } else {
    x.to_string()
  }
}

///|
/// The values Ruby's `(from..to).step(by)` yields for floats: each
/// `from + i * by`, as many as fit with a little slack for rounding, the
/// last one no further than `to` (Ruby's `ruby_float_step`).
fn ruby_steps(from : Double, to : Double, by : Double) -> Array[Double] {
  let n = (to - from) / by
  let mut err = (from.abs() + to.abs() + (to - from).abs()) /
    by.abs() *
    2.220446049250313e-16
  if err > 0.5 {
    err = 0.5
  }
  let count = (n + err).floor()
  let out = []
  let mut i = 0.0
  while i <= count {
    // (Ruby's C may fuse this into one rounding, depending on how it was
    // compiled: a step with no exact binary value may then differ in its
    // last digit)
    let d = i * by + from
    out.push(if by >= 0.0 && to < d { to } else { d })
    i += 1.0
  }
  out
}

///|
/// A Float as Ruby prints it: a whole one with `.0`.
fn ruby_float_string(x : Double) -> String {
  let s = x.to_string()
  if s.contains(".") || s.contains("e") || s.contains("N") || s.contains("I") {
    s
  } else {
    s + ".0"
  }
}
