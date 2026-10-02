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
/// asciidoctor-pdf's SourceWrap: `fragments` (a numbered source block, each
/// line starting with its line number, `Style::linenum`) with every line
/// that wraps in `width` broken where it wraps: a line break, then the
/// number's blank (a no-break space and spaces, as wide as the number),
/// the line's highlight mark if it has one (`Style::line_mark`), and the
/// rest of the line without the white space it starts with. Each pass
/// breaks the first line that wraps, the lines before it unchanged.
///
/// None when a line cannot fit: one that would hold nothing but its number
/// (or blank) and mark, as Prawn raises `Prawn::Errors::CannotFit` when no
/// text fits on a line.
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
    let mut cut : Int? = None
    for index, range in ranges {
      let (start, end, hard) = range
      if hard || index == ranges.length() - 1 {
        continue
      }
      if end < items.length() {
        // no progress: nothing but the number (or blank) and the mark fits
        let holds_text = start <= end &&
          items[start:end]
          .iter()
          .any(item => {
            let style = fragments[item.fragment].style
            !style.linenum && !style.line_mark && item.unit != 0x200B
          })
        if !holds_text {
          return None
        }
        cut = Some(end)
        break
      }
    }
    guard cut is Some(at) else { break }
    let item = items[at]
    let f = item.fragment
    let fragment = fragments[f]
    let offset = if item.offset >= 0 { item.offset } else { 0 }
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
    let blank = "\u{a0}" + " ".repeat(linenum.text.length() - 1)
    let next : Array[Fragment] = []
    for i in 0..<f {
      next.push(fragments[i])
    }
    if offset > 0 {
      next.push({ ..fragment, text: fragment.text[:offset].to_owned(), })
    }
    next.push({
      text: "\n",
      style: { ..fragment.style, background: None, },
      anchor: None,
    })
    next.push({ ..linenum, text: blank, })
    match mark {
      Some(m) => next.push(m)
      None => ()
    }
    next.push({ ..fragment, text: lstrip(fragment.text[offset:].to_owned()), })
    for i in (f + 1)..<fragments.length() {
      next.push(fragments[i])
    }
    fragments = next
  }
  Some(fragments)
}

///|
/// Ruby's `String#lstrip`.
fn lstrip(s : String) -> String {
  let mut start = 0
  while start < s.length() {
    let c = s[start]
    if c == ' ' ||
      c == '\t' ||
      c == '\n' ||
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
