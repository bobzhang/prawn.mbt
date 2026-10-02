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
/// starts with. A number (or blank) wider than the line breaks before its
/// trailing blanks, the line's text going on a line of its own, as Prawn
/// breaks it. Each pass breaks the first line that wraps, consuming some of
/// the source's text or of a number's blanks, so the passes end.
///
/// None when a line cannot fit, as Prawn raises `Prawn::Errors::CannotFit`:
/// its number (or blank) without its blanks is wider than the line, or it
/// would hold nothing else.
pub fn source_wrap(
  fragments : Array[Fragment],
  ctx : TextContext,
  width : Double,
) -> Array[Fragment]? {
  guard fragments.get(0) is Some(first) && first.style.linenum else {
    return Some(fragments)
  }
  // the blank of every wrapped line, as wide as the block's first number
  // (SourceWrap's `linenum_spacer ||=`)
  let spacer = "\u{a0}" + " ".repeat(first.text.length() - 1)
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
    let mut split_number : Array[Fragment]? = None
    for index, range in ranges {
      let (start, end, hard) = range
      // a line whose first glyph is wider than it (text a too-wide number
      // put on a line of its own, say): Prawn's CannotFit
      let mut first = start
      while first < end && items[first].fit <= 0.0 {
        first += 1
      }
      if first < end &&
        !fragments[items[first].fragment].style.linenum &&
        items[first].fit > width + 0.0001 {
        return None
      }
      // the number (or blank) the line starts with, when it is wider than
      // the line: Prawn breaks it before its trailing blanks, which the
      // next line strips, so the line's text goes on a line of its own (a
      // number too wide without them cannot fit)
      if start < end && fragments[items[start].fragment].style.linenum {
        let f = items[start].fragment
        let text = fragments[f].text
        let mut keep = text.length()
        while keep > 0 && (text[keep - 1] == ' ' || text[keep - 1] == '\t') {
          keep -= 1
        }
        let mut full = 0.0
        let mut digits = 0.0
        let mut k = start
        while k < items.length() && items[k].fragment == f {
          full += items[k].fit
          if items[k].offset < keep {
            digits += items[k].fit
          }
          k += 1
        }
        if full > width + 0.0001 {
          if keep == 0 || digits > width + 0.0001 {
            return None
          }
          let plain = plain_number_style(fragments[f].style)
          split_number = Some(
            [
              ..fragments[:f],
              { ..fragments[f], text: text[:keep].to_owned(), },
              { text: "\n", style: { ..plain, linenum: false, }, anchor: None, },
              ..strip_line_start([..fragments[f + 1:]]),
            ],
          )
          break
        }
      }
      if hard || index == ranges.length() - 1 || end >= items.length() {
        continue
      }
      cut = Some((start, end))
      break
    }
    if split_number is Some(next) {
      fragments = next
      continue
    }
    guard cut is Some((start, at)) else { break }
    let f = items[at].fragment
    let fragment = fragments[f]
    // what the line keeps of the fragment the break falls in: up to the
    // character; at the padding after a bordered fragment, which the line
    // cannot hold, the fragment wraps itself, at its last blank that leaves
    // room for the padding, else (with no text before it on the line) by
    // character; else it goes to the next line whole
    let mut at = at
    if items[at].unit == pad_unit && at > start && items[at - 1].fragment == f {
      let pad = items[at].fit
      let mut used = 0.0
      for k in start..<at {
        used += items[k].fit
      }
      let mut fits = at
      while fits > start &&
            items[fits - 1].fragment == f &&
            items[fits - 1].offset >= 0 &&
            used + pad > width + 0.0001 {
        fits -= 1
        used -= items[fits].fit
      }
      let mut blank = fits
      while blank > start &&
            items[blank - 1].fragment == f &&
            items[blank - 1].offset >= 0 &&
            items[blank - 1].unit != ' '.to_int() {
        blank -= 1
      }
      let before = items[start:at]
        .iter()
        .any(it => is_text(it) && it.fragment < f)
      at = if blank > start &&
        items[blank - 1].fragment == f &&
        items[blank - 1].offset >= 0 &&
        blank < at {
        blank
      } else if !before &&
        fits > start &&
        items[fits - 1].fragment == f &&
        items[fits - 1].offset >= 0 {
        fits
      } else {
        at
      }
    }
    let item = items[at]
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
    // its mark: right after the number, or after the line break where the
    // number was too wide and broke
    let mark = fragments[number + 1:f].iter().find_first(m => m.style.line_mark)
    let plain = plain_number_style(linenum.style)
    let next : Array[Fragment] = []
    for i in 0..<f {
      next.push(fragments[i])
    }
    if offset > 0 {
      next.push({ ..fragment, text: fragment.text[:offset].to_owned(), })
    }
    next.push({ text: "\n", style: { ..plain, linenum: false, }, anchor: None, })
    next.push({ text: spacer, style: plain, anchor: None, })
    match mark {
      Some(m) => next.push(m)
      None => ()
    }
    // the rest of the line, without the blanks it starts with
    next.append(
      strip_line_start(
        [
          { ..fragment, text: fragment.text[offset:].to_owned(), },
          ..fragments[f + 1:],
        ],
      ),
    )
    fragments = next
  }
  Some(fragments)
}

///|
/// `rest`, the fragments of a line that wrapped, its first fragment with
/// text without the blanks it starts with (SourceWrap's and Prawn's
/// `lstrip`; a line break stays), empty fragments dropped.
fn strip_line_start(rest : Array[Fragment]) -> Array[Fragment] {
  let out = []
  let mut stripping = true
  for r in rest {
    if stripping && r.text != "" {
      let text = strip_blanks(r.text)
      stripping = false
      if text != "" {
        out.push({ ..r, text, })
      }
    } else if r.text != "" || r.anchor is Some(_) {
      out.push(r)
    }
  }
  out
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
