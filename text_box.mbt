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
  string : String,
  at : (Double, Double),
  width : Double,
  height : Double,
  size : Double,
  align : Alignment,
  leading : Double,
  dry_run? : Bool = false,
) -> (Array[Fragment], Double) raise PrawnError {
  // a dry run calls no callbacks
  let was_dry = self.dry_run
  self.dry_run = was_dry || dry_run
  defer {
    self.dry_run = was_dry
  }
  let style = self.style(size~)
  let flow = self.flow
  let page = flow.page
  let mark = flow.model.pages[page].items.length()
  let ctx = flow.text()
  let face = flow.font(style)
  let top = flow.page_h() - at.1
  // Prawn's `Wrap#wrap`: line by line, each stripped of its leading
  // whitespace and wrapped, CannotFit when not even its first character
  // fits, set when it fits the height; the first that does not is where
  // the box ends
  let mut remaining = ctx.apply_fallbacks([
    { text: string, style, anchor: None, },
  ])
  let mut baseline = 0.0
  let mut placed = 0
  let mut last : Double? = None
  let mut depth = 0.0
  while !remaining.is_empty() {
    let line_fragments = strip_leading_fragments(remaining)
    if line_fragments.is_empty() {
      remaining = []
      break
    }
    // measured in the font it is set in (a fallback font, maybe)
    let first = line_fragments[0]
    let first_face = flow.font(first.style)
    match first.text.iter().next() {
      Some(c) if c != '\n' &&
        first_face.prawn_width(c.to_int()) * (first.style.size / 1000.0) > width => {
        if dry_run {
          flow.model.pages[page].items.truncate(mark)
        }
        raise CannotFit
      }
      _ => ()
    }
    let (line, rest) = split_first_line(
      line_fragments, line_fragments, ctx, width, align,
    )
    let (a, d, h) = line_extent(line, face, size, false)
    let next = if placed == 0 { a } else { baseline + h + leading }
    if next + d > height + 0.0001 {
      remaining = line_fragments
      break
    }
    baseline = next
    flow.ink_line(line, at.0, top + baseline)
    last = Some(top + baseline)
    depth = d
    placed += 1
    remaining = rest
  }
  if dry_run {
    flow.model.pages[page].items.truncate(mark)
  }
  let printed = match last {
    Some(b) => b - top + depth
    None => 0.0
  }
  (remaining, printed)
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
  align? : Alignment = Left,
  valign? : VerticalAlignment = Top,
  overflow? : Overflow = Truncate,
  min_font_size? : Double = 5.0,
  leading? : Double = 0.0,
  rotate? : Double = 0.0,
  rotate_around? : String = "upper_left",
  draw_text_callback? : (String, (Double, Double), Bool) -> Unit,
) -> String raise {
  let saved_callback = self.draw_text_callback
  self.draw_text_callback = draw_text_callback
  defer {
    self.draw_text_callback = saved_callback
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
  if overflow is ShrinkToFit {
    while true {
      let (rest, _) = self.set_box(
        string,
        (left, top),
        width,
        height,
        size,
        align,
        leading,
        dry_run=true,
      )
      if rest.is_empty() || size <= min_font_size {
        break
      }
      size = @cmp.maximum(size - 0.5, min_font_size)
    }
  }
  if !(valign is Top) {
    let (_, printed) = self.set_box(
      string,
      (left, top),
      width,
      height,
      size,
      align,
      leading,
      dry_run=true,
    )
    let descender = self.flow.font(self.style(size~)).descender_pt(size)
    match valign {
      Center => top -= (height - printed + descender) * 0.5
      _ => top -= height - printed
    }
    at = (at.0, at.1 - (origin.1 - top))
    height = printed
  }
  let set = () => {
    let (rest, _) = self.set_box(
      string,
      (left, top),
      width,
      height,
      size,
      align,
      leading,
    )
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
/// strips a line's leading whitespace).
fn strip_leading_fragments(fragments : Array[Fragment]) -> Array[Fragment] {
  let out : Array[Fragment] = []
  let mut stripping = true
  for f in fragments {
    if stripping {
      let text = strip_leading_spaces(f.text)
      if text.is_empty() && f.anchor is None {
        continue
      }
      stripping = false
      out.push({ ..f, text, })
    } else {
      out.push(f)
    }
  }
  out
}
