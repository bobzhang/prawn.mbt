///|
// Prawn's text boxes (`text_box`, `Prawn::Text::Box`): text set in a box
// at a point of the bounds, as much as fits, without moving the cursor.

///|
/// What a text box does with text that does not fit (`overflow`).
pub(all) enum Overflow {
  /// set what fits; the rest is returned
  Truncate
  /// set smaller, half a point at a time, down to `min_font_size`
  ShrinkToFit
  /// the box reaches down to the bottom of the bounds
  Expand
}

///|
/// Where a text box puts its lines vertically (`valign`).
pub(all) enum VerticalAlignment {
  Top
  Center
  Bottom
}

///|
/// The text of fragments.
fn text_of_fragments(fragments : Array[Fragment]) -> String {
  let sb = StringBuilder()
  for f in fragments {
    sb.write_string(f.text)
  }
  sb.to_string()
}

///|
/// Sets `string` in a box whose top left corner is `at` on the page (Prawn's
/// coordinates), `width` by `height`, at `size`: the fragments that did not
/// fit, and how tall what was set is (Prawn's box `height`). With `dry_run`
/// nothing stays on the page.
fn Document::set_box(
  self : Document,
  fragments : Array[Fragment],
  base : Style,
  at : (Double, Double),
  width : Double,
  height : Double,
  align : Alignment,
  leading : Double,
  dry_run? : Bool = false,
) -> (Array[Fragment], Double, Double) raise PrawnError {
  // a dry run calls no callbacks
  let was_dry = self.dry_run
  self.dry_run = was_dry || dry_run
  defer {
    self.dry_run = was_dry
  }
  let page = self.page()
  let mark = page.items.length()
  let ctx = self.text_context
  let face = self.face_of(base)
  // the box's top left in the bounds (where Prawn keeps a box's `at`):
  // each line is drawn on the page current then, which a callback may
  // change
  let box = self.current_box()
  let left = at.0 - box.left
  let top = at.1 - box.bottom_at(self.y())
  // Prawn's `Wrap#wrap`: line by line, each stripped of its leading
  // whitespace and wrapped, CannotFit when not even its first character
  // fits, set when it fits the height; the first that does not is where
  // the box ends
  // the text, as Prawn's arranger takes it in (an empty fragment is none)
  let text = ctx
    .apply_fallbacks(fragments)
    .filter(f => !f.text.is_empty() || f.anchor is Some(_) || f.style.image >= 0)
  // where the text not yet set starts: a fragment, and an offset in it
  let mut at_fragment = 0
  let mut at_offset = 0
  let mut baseline = 0.0
  let mut placed = 0
  // the last line measured (whether or not it fit): Prawn takes the box's
  // height and final gap from it
  let mut depth = 0.0
  let mut gap = 0.0
  let mut rejected = false
  while at_fragment < text.length() {
    let window = line_window(text, at_fragment, at_offset, self, width)
    let (stripped, origins) = strip_leading_fragments(window)
    // measured in the font it is set in (a fallback font, maybe)
    match stripped.search_by(f => !f.text.is_empty()) {
      Some(i) => {
        let first = stripped[i]
        let first_face = self.face_of(first.style)
        match first.text.iter().next() {
          Some(c) if c != '\n' &&
            first_face.prawn_width(c.to_int()) * (first.style.size / 1000.0) >
            width => {
            if dry_run {
              page.truncate(mark)
            }
            raise CannotFit
          }
          _ => ()
        }
      }
      None => ()
    }
    // a fragment emptied counts towards the line's height (Prawn keeps
    // it): a zero-width space holds its place
    let held = stripped.map(f => {
      if f.text.is_empty() && f.anchor is None && f.style.image < 0 {
        { ..f, text: "\u{200B}", }
      } else {
        f
      }
    })
    let (line, after) = first_line_break(held, ctx, width, align)
    let (a, d, h) = line_extent(line, face, base.size, false)
    depth = d
    // the box's line gap is its last line's (its largest font's)
    gap = h - a - d
    let next = if placed == 0 { a } else { baseline + h + leading }
    if next + d > height + 0.0001 {
      rejected = true
      break
    }
    baseline = next
    self.ink_line(line, left, top - baseline)
    placed += 1
    // the text after the line, in the text's terms
    let (w, offset) = match after {
      Some((i, o)) => {
        let (w, removed) = origins[i]
        (w, removed + (if held[i].text == "\u{200B}" { 0 } else { o }))
      }
      None => (window.length() - 1, window[window.length() - 1].text.length())
    }
    let base_offset = if w == 0 { at_offset } else { 0 }
    let before = (at_fragment, at_offset)
    at_fragment += w
    at_offset = base_offset + offset
    let length = text[at_fragment].text.length()
    if (after is None || at_offset > 0) && at_offset >= length {
      at_fragment += 1
      at_offset = 0
    }
    // every line takes some of the text
    guard (at_fragment, at_offset) != before else {
      abort("a line took none of the text")
    }
  }
  if dry_run {
    page.truncate(mark)
  }
  let remaining : Array[Fragment] = []
  if at_fragment < text.length() {
    let f = text[at_fragment]
    remaining.push({ ..f, text: f.text[at_offset:].to_owned(), })
    for i in (at_fragment + 1)..<text.length() {
      remaining.push(text[i])
    }
  }
  // a line that did not fit goes back without the whitespace it starts
  // with, as Prawn has stripped it
  let remaining = if rejected {
    strip_leading_fragments(remaining).0
  } else {
    remaining
  }
  (remaining, baseline + depth, gap)
}

///|
/// Prawn's `text_box`: `string` set in a box at `at` (a point of the bounds,
/// by default their top left), `width` wide (by default to the bounds'
/// right) and `height` tall (by default to the bottom of the bounds, or of
/// the box a stretchy box is in), as `overflow` says; the text that did not
/// fit is returned. The cursor does not move.
pub fn Document::text_box(
  self : Document,
  string : String,
  at? : (Double, Double),
  width? : Double,
  height? : Double,
  size? : Double,
  style? : FontStyle,
  align? : Alignment = Left,
  valign? : VerticalAlignment = Top,
  overflow? : Overflow = Truncate,
  min_font_size? : Double = 5.0,
  leading? : Double,
  rotate? : Double = 0.0,
  rotate_around? : String = "upper_left",
  draw_text_callback? : (String, (Double, Double), Bool) -> Unit,
) -> String raise {
  // the current font in `style` while this is set (Prawn's `:style`, which
  // its boxes apply and undo)
  let saved_style = self.face_style
  defer {
    self.face_style = saved_style
  }
  match style {
    Some(style) => {
      // a font set by its own name has no family to take a style from
      if !self.font_family_known {
        raise BadFontFamily("PDF::Core::Text::BadFontFamily")
      }
      self.face_style = style.flags()
    }
    None => ()
  }
  // the document's default leading unless given (Prawn's `default_leading`)
  let leading = leading.unwrap_or(self.default_leading)
  let saved_callback = self.draw_text_callback
  self.draw_text_callback = draw_text_callback
  // a text box does not move the position; callbacks may, and it stays
  // where they leave it
  defer {
    self.draw_text_callback = saved_callback
    self.track()
  }
  let bounds = self.bounds()
  let mut at = at.unwrap_or((0.0, bounds.height))
  let width = width.unwrap_or(bounds.width - at.0)
  // the default height reaches the bottom of the bounds, or of the fixed
  // box a stretchy one is in (Prawn's `default_height`)
  let default_height = () => {
    let y = self.y()
    let box = self.current_box()
    // out through stretchy boxes to one that has a bottom
    let mut frame = box
    while frame.height is None {
      match frame.parent {
        Some(p) => frame = p
        None => break
      }
    }
    at.1 + box.bottom_at(y) - frame.bottom_at(y)
  }
  let (box_height, overflow) = match overflow {
    Expand => (default_height(), Truncate)
    _ => (height.unwrap_or(default_height()), overflow)
  }
  let mut height = box_height
  // encoding first, for the whole string; whether a character fits is
  // checked on the lines Prawn tries to set (`set_box`)
  let style = self.style(size?)
  self.check(string, style, None)
  let mut size = style.size
  // the box on the page
  let origin = self.absolute(at)
  let mut top = origin.1
  let left = origin.0
  // the string set at `size` in the box `h` tall with its top at `y`: a
  // dry run, or for good
  let set_at = fn(
    size : Double,
    y : Double,
    h : Double,
    dry : Bool,
  ) raise PrawnError {
    let st = self.style(size~)
    self.set_box(
      [{ text: string, style: st, anchor: None, }],
      st,
      (left, y),
      width,
      h,
      align,
      leading,
      dry_run=dry,
    )
  }
  if overflow is ShrinkToFit {
    while true {
      let (rest, _, _) = set_at(size, top, height, true)
      if rest.is_empty() || size <= min_font_size {
        break
      }
      size = @cmp.maximum(size - 0.5, min_font_size)
    }
  }
  if !(valign is Top) {
    let (_, printed, _) = set_at(size, top, height, true)
    let descender = self.face_of(self.style(size~)).descender_pt(size)
    match valign {
      Center => top -= (height - printed + descender) * 0.5
      _ => top -= height - printed
    }
    at = (at.0, at.1 - (origin.1 - top))
    height = printed
  }
  let set = () => {
    let (rest, _, _) = set_at(size, top, height, false)
    text_of_fragments(rest)
  }
  if rotate == 0.0 {
    return set()
  }
  // about a corner or the center of the box, as a point of the bounds
  let around = match rotate_around {
    "center" => (at.0 + width * 0.5, at.1 - height * 0.5)
    "upper_right" => (at.0 + width, at.1)
    "lower_right" => (at.0 + width, at.1 - height)
    "lower_left" => (at.0, at.1 - height)
    _ => at
  }
  let mut rest = ""
  self.rotate(rotate, origin=around, () => rest = set())
  rest
}

///|
/// Prawn's whitespace (`LineWrap#whitespace`): space, tab, zero-width
/// space.
fn is_prawn_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\u{200B}'
}

///|
fn strip_leading_spaces(text : String) -> String {
  let mut i = 0
  while i < text.length() && is_prawn_space(text[i].unsafe_to_char()) {
    i = i + 1
  }
  text[i:].to_owned()
}

///|
/// Fragments without the whitespace they start with (Prawn's line wrap
/// strips a line's leading whitespace), and where each comes from: its
/// index in `fragments` and how much was stripped from its start. A
/// fragment it empties stays, as Prawn keeps it, unless a line break
/// follows it.
fn strip_leading_fragments(
  fragments : Array[Fragment],
) -> (Array[Fragment], Array[(Int, Int)]) {
  let out : Array[Fragment] = []
  let origins : Array[(Int, Int)] = []
  let mut stripping = true
  for i, f in fragments {
    if stripping {
      let text = strip_leading_spaces(f.text)
      let removed = f.text.length() - text.length()
      if text.is_empty() && f.anchor is None && f.style.image < 0 {
        if i + 1 < fragments.length() && fragments[i + 1].text.has_prefix("\n") {
          continue
        }
        out.push({ ..f, text, })
        origins.push((i, removed))
        continue
      }
      stripping = false
      out.push({ ..f, text, })
      origins.push((i, removed))
    } else {
      out.push(f)
      origins.push((i, 0))
    }
  }
  (out, origins)
}

///|
/// A window of `text` from fragment `start` at `offset` that surely holds
/// the first line set `width` wide: up to a line break, or the second
/// break opportunity past twice the width, or four times the width. A
/// long text is then not wrapped (nor copied) in full for each line.
fn line_window(
  text : Array[Fragment],
  start : Int,
  offset : Int,
  doc : Document,
  width : Double,
) -> Array[Fragment] {
  let window : Array[Fragment] = []
  let mut w = 0.0
  let mut breaks = 0
  // the whitespace the line starts with is stripped: it takes no room
  let mut leading = true
  // the window holds a character past it whatever the width (one wider
  // than the line is Prawn's CannotFit)
  let mut taken = false
  for i in start..<text.length() {
    let f = text[i]
    let from = if i == start { offset } else { 0 }
    let s = f.text
    let face = doc.face_of(f.style)
    let scale = f.style.size / 1000.0
    let mut cut = -1
    for j in from..<s.length() {
      let u = s[j].to_int()
      if u == '\n'.to_int() {
        cut = j + 1
        break
      }
      if leading {
        if u == ' '.to_int() || u == '\t'.to_int() || u == 0x200B {
          continue
        }
        leading = false
      }
      // never between the halves of a surrogate pair
      let low = u >= 0xDC00 && u <= 0xDFFF
      if taken && w > 4.0 * width && !low {
        cut = j
        break
      }
      if taken &&
        w > 2.0 * width &&
        (
          u == ' '.to_int() ||
          u == '\t'.to_int() ||
          u == 0x200B ||
          u == '-'.to_int() ||
          u == 0xAD
        ) {
        breaks += 1
        if breaks >= 2 {
          cut = j
          break
        }
      }
      // a soft hyphen takes no room in a line (but the one ending it)
      if u != 0xAD {
        w += face.prawn_width(u) * scale
      }
      taken = true
    }
    let to = if cut >= 0 { cut } else { s.length() }
    window.push(
      if from == 0 && to == s.length() {
        f
      } else {
        { ..f, text: s[from:to].to_owned(), }
      },
    )
    if cut >= 0 {
      break
    }
  }
  window
}
