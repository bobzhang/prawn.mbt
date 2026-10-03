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
  let style = self.style(size~)
  let flow = self.flow
  let saved_y = flow.y
  let page = flow.page
  let mark = flow.model.pages[page].items.length()
  flow.y = flow.page_h() - at.1
  let (rest, last) = flow.typeset_box(
    [{ text: string, style, anchor: None, }],
    { leading, padding_top: 0.0, padding_bottom: 0.0, },
    style,
    align~,
    x=at.0,
    width~,
    height~,
    text_indent=0.0,
  )
  let printed = match last {
    Some(baseline) =>
      baseline - flow.y + flow.font(style).descender_pt(style.size)
    None => 0.0
  }
  flow.y = saved_y
  let drop = () => flow.model.pages[page].items.truncate(mark)
  if dry_run {
    drop()
  }
  // Prawn wraps each line before it knows whether the line fits the box:
  // the lines set and the next one; a character on them too wide for the
  // box is CannotFit
  let next_rest = if rest.is_empty() {
    ""
  } else {
    let (_, after) = split_first_line(rest, rest, flow.text(), width, align)
    text_of_fragments(after)
  }
  let tried = string.length() - next_rest.length()
  let scale = size / 1000.0
  let face = flow.font(style)
  for c in string[:tried] {
    if !is_prawn_space(c) &&
      c != '\n' &&
      face.prawn_width(c.to_int()) * scale > width {
      // raised before anything is set
      drop()
      raise CannotFit
    }
  }
  (rest, printed)
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
) -> String raise {
  let bounds = self.bounds()
  let mut at = at.unwrap_or((0.0, bounds.height))
  let width = width.unwrap_or(bounds.width - at.0)
  // the default height reaches the bottom of the bounds, or of the fixed
  // box a stretchy one is in (Prawn's `default_height`)
  let default_height = () => {
    let y = self.y()
    let box = self.current_box()
    let mut frame : Box? = None
    for i = self.boxes.length() - 1; i >= 0; i = i - 1 {
      if self.boxes[i].height is Some(_) {
        frame = Some(self.boxes[i])
        break
      }
    }
    let frame_bottom = match frame {
      Some(f) => f.top - f.height_at(y)
      // every box stretchy: the margin box
      None => self.flow.page_h() - box.margin_bottom
    }
    at.1 + (box.top - box.height_at(y)) - frame_bottom
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
    // the line that did not fit was wrapped first: its leading spaces are
    // gone (Prawn's line wrap strips them)
    strip_leading_spaces(text_of_fragments(rest))
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
