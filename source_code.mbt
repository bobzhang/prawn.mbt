///|
// Source blocks as asciidoctor-pdf lays them out when they are highlighted:
// the backgrounds its highlighters' fragment callbacks paint
// (Rouge's BackgroundColorizer, TextBackgroundAndBorderRenderer) and its
// SourceWrap extension of Prawn's text box (formatted_text/source_wrap.rb).

///|
/// How far the background of a fragment of a highlighted source block
/// reaches, when not just its glyph box.
pub(all) enum CodeBackground {
  /// Rouge's BackgroundColorizer on an inline block: the glyph box grown by
  /// the line gap (`code_line_gap`, half above, half below), and to the
  /// right edge of the bounds when the fragment extends
  Gap(Double, Bool)
  /// asciidoctor-pdf's TextBackgroundAndBorderRenderer on an inline block:
  /// the height of the font's line centred on the glyph box, to the right
  /// edge of the bounds
  FullLine
} derive(Eq)

///|
pub extend CodeBackground with Eq::{not_equal, equal}

///|
/// The background of a fragment of a highlighted source block that reaches
/// past its glyph box, for a run at `x`, `width` wide, on the line at
/// `baseline` (the fragment's font `face` at `size`).
fn Flow::code_background_item(
  self : Flow,
  extent : CodeBackground,
  x : Double,
  width : Double,
  baseline : Double,
  face : Face,
  size : Double,
  color : @pagelayout.Color,
) -> @pagelayout.PageItem {
  let a = face.ascender_pt(size)
  let d = face.descender_pt(size)
  match extent {
    Gap(gap, to_edge) =>
      rect_item(
        x,
        baseline - a - gap * 0.5,
        if to_edge {
          self.right - x
        } else {
          width
        },
        a + d + gap,
        fill=color,
      )
    FullLine => {
      let h = face.height_pt(size)
      rect_item(
        x,
        baseline - a - (h - (a + d)) * 0.5,
        self.right - x,
        h,
        fill=color,
      )
    }
  }
}

///|
/// The style of what source_wrap adds for a wrapped line, from its line
/// number's: the number's blank (a line number, but unstyled, as
/// asciidoctor-pdf's spacer has no style of its own: no background, no
/// bold) and the line break before it.
fn plain_number_style(style : Style) -> Style {
  {
    ..style,
    bold: false,
    italic: false,
    underline: false,
    strike: false,
    background: None,
    code_background: None,
    border_offset: 0.0,
  }
}

///|
/// asciidoctor-pdf's SourceWrap: `fragments` (a numbered source block, each
/// line starting with its line number, `Style::linenum`) with every line
/// that wraps in `width` broken where it wraps: a line break, then the
/// number's blank (a no-break space and spaces as wide as the number, in
/// no style of its own), the line's highlight mark if it has one
/// (`Style::line_mark`), and the rest of the line without the blanks it
/// starts with. Each pass breaks the first line that wraps, and consumes
/// some of the source's text, so the passes end.
///
/// None when a line cannot fit, as Prawn raises `Prawn::Errors::CannotFit`:
/// its number (or blank) and mark alone are wider than the line, or it
/// would hold nothing else.
pub fn source_wrap(
  fragments : Array[Fragment],
  ctx : TextContext,
  width : Double,
) -> Array[Fragment]? {
  guard fragments.get(0) is Some(first) && first.style.linenum else {
    return Some(fragments)
  }
  let mut fragments = ctx.apply_fallbacks(fragments)
  while true {
    let (items, _, ranges) = break_lines(fragments, ctx, width, width)
    // whether an item is text of the source (not a number, a mark, a
    // dropped space or the padding of a bordered fragment)
    let is_text = (item : Item) => {
      let style = fragments[item.fragment].style
      !style.linenum &&
      !style.line_mark &&
      item.unit != 0x200B &&
      item.unit != pad_unit &&
      item.offset >= 0
    }
    let mut cut : (Int, Int)? = None
    for index, range in ranges {
      let (start, end, hard) = range
      let mut gutter = 0.0
      for k in start..<end {
        if fragments[items[k].fragment].style.linenum {
          gutter += items[k].fit
        }
      }
      if gutter > width + 0.0001 {
        return None
      }
      if hard || index == ranges.length() - 1 || end >= items.length() {
        continue
      }
      cut = Some((start, end))
      break
    }
    guard cut is Some((start, at)) else { break }
    let item = items[at]
    let f = item.fragment
    let fragment = fragments[f]
    // what the line keeps of the fragment the break falls in: up to the
    // character, or, at the padding of a bordered fragment, nothing (the
    // fragment goes to the next line whole, padding and all)
    let offset = if item.offset >= 0 { item.offset } else { 0 }
    // the line must keep some text, or what is left would wrap the same way
    // again: Prawn's CannotFit
    let kept = items[start:at]
      .iter()
      .any(it => is_text(it) && (it.fragment < f || offset > 0))
    if !kept {
      return None
    }
    // the number and mark of the source line this one continues
    let mut number = f
    while number >= 0 && !fragments[number].style.linenum {
      number -= 1
    }
    guard number >= 0 else { return None }
    let linenum = fragments[number]
    let mark = match fragments.get(number + 1) {
      Some(m) if m.style.line_mark => Some(m)
      _ => None
    }
    let plain = plain_number_style(linenum.style)
    let next : Array[Fragment] = []
    for i in 0..<f {
      next.push(fragments[i])
    }
    if offset > 0 {
      next.push({ ..fragment, text: fragment.text[:offset].to_owned(), })
    }
    next.push({ text: "\n", style: { ..plain, linenum: false, }, anchor: None, })
    next.push({
      text: "\u{a0}" + " ".repeat(linenum.text.length() - 1),
      style: plain,
      anchor: None,
    })
    match mark {
      Some(m) => next.push(m)
      None => ()
    }
    // the rest of the line, its first fragment without the blanks it
    // starts with (SourceWrap's lstrip; a line break stays)
    let rest = [
      { ..fragment, text: fragment.text[offset:].to_owned(), },
      ..fragments[f + 1:],
    ]
    let mut stripping = true
    for r in rest {
      if stripping && r.text != "" {
        let text = strip_blanks(r.text)
        stripping = false
        if text != "" {
          next.push({ ..r, text, })
        }
      } else if r.text != "" || r.anchor is Some(_) {
        next.push(r)
      }
    }
    fragments = next
  }
  Some(fragments)
}

///|
/// The text without the blanks it starts with (Ruby's `lstrip`, but a line
/// break, which in Prawn would be a fragment of its own, stays).
fn strip_blanks(s : String) -> String {
  let mut start = 0
  while start < s.length() {
    let c = s[start]
    if c == ' ' ||
      c == '\t' ||
      c == '\r' ||
      c == '\u{0B}' ||
      c == '\u{0C}' ||
      c == '\u{00}' {
      start += 1
    } else {
      break
    }
  }
  s[start:].to_owned()
}
