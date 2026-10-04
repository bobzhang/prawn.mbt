///|
// Line breaking of formatted text, following Prawn's greedy wrap
// (Prawn::Text::Formatted::LineWrap): each fragment is cut into tokens —
// runs of word characters (ending in hyphens or a soft hyphen when they
// have them), runs of whitespace, and runs of hyphens with the word after
// them — and a line may break between any two tokens, and between
// fragments. A token longer than the line wraps by character, spaces
// starting a line are dropped and trailing ones do not count, and a
// justified line widens its spaces, except on the last line of a paragraph
// and before a hard break.
//
// Two widths are tracked per character. `fit` is Prawn's (glyph widths
// truncated to 1/1000 em, kerned within a token only, as Prawn measures
// token by token) and decides where lines break, so breaks match Ruby;
// `draw` is the width the PDF declares for the glyph, kerned with the next
// character of the fragment as Prawn draws it, and places glyphs, so the
// emitted text needs a displacement only where kerning or justification
// moves a glyph.

///|
pub(all) enum Alignment {
  Left
  Center
  Right
  Justify
} derive(Eq)

///|
pub extend Alignment with Eq::{not_equal, equal}

///|
pub(all) struct Item {
  unit : Int
  fragment : Int
  mut fit : Double
  draw : Double
  /// kerning with the next character, points; part of `draw`, and of
  /// `fit` unless a token boundary falls between the two
  kern : Double
  hard_break : Bool
  anchor : String?
  /// the position of its code unit in its fragment's text, or -1
  offset : Int
}

///|
/// One placed run of a line; `x` is relative to the line's left edge.
pub(all) struct LineRun {
  /// the index of the fragment it is part of
  fragment : Int
  text : String
  style : Style
  face : Face
  x : Double
  advances : Array[Double]
  width : Double
}

///|
pub(all) struct Line {
  runs : Array[LineRun]
  anchors : Array[(String, Double)]
  /// the width Prawn measures (truncated glyph widths)
  fit_width : Double
  ascender : Double
  descender : Double
  height : Double
  /// links whose fragment has nothing on the line but the spaces ending
  /// it: Prawn still annotates them, with no width, at the line's end
  /// (x, style, face)
  empty_links : Array[(Double, Style, Face)]
  /// inline images: x, their index, width, height, whether they make the
  /// line taller, and their fragment's style and face
  images : Array[(Double, Int, Double, Double, Bool, Style, Face)]
  /// the line marks of highlighted source lines (`Style::line_mark`): x,
  /// their fragment's style and face
  marks : Array[(Double, Style, Face)]
  /// every fragment the line holds, in order (Prawn draws each, one with
  /// nothing to show on the line too): its index, the x it starts at, its
  /// style and face
  held : Array[(Int, Double, Style, Face)]
}

///|
/// The unit of an item that only takes up room: the padding a fragment
/// with a `border_offset` has on each side.
let pad_unit = -1

///|
fn is_break_space(unit : Int) -> Bool {
  unit == 0x20
}

///|
/// Prawn's whitespace break characters: space, tab, zero-width space.
fn is_whitespace(unit : Int) -> Bool {
  unit == 0x20 || unit == 0x09 || unit == 0x200B
}

///|
/// Where Prawn's tokens start: `starts[i]` when a line may break before
/// `items[i]`.
fn token_starts(items : Array[Item]) -> Array[Bool] {
  let n = items.length()
  let starts = Array::make(n, false)
  let kind = fn(i : Int) -> Int {
    let unit = items[i].unit
    // an anchor stands for asciidoctor-pdf's placeholder text, a NUL: part
    // of the word it touches, and no break opportunity
    if items[i].anchor is Some(_) {
      0
    } else if is_whitespace(unit) {
      1
    } else if unit == 0x2D {
      2
    } else if unit == 0xAD {
      3
    } else {
      0
    }
  }
  let mut i = 0
  while i < n {

    // tokens run across fragments: Prawn pulls the last word of a fragment
    // onto the next line with the word the next fragment starts with (its
    // `pull_preceding_fragment_to_join_this_one?`), so a style change
    // inside a word is no break opportunity; a hard break ends every token
    let mut end = i + 1
    while end < n && !items[end].hard_break {
      end += 1
    }
    let mut pos = i
    while pos < end {
      starts[pos] = true
      let mut j = pos
      match kind(pos) {
        0 => {
          while j < end && kind(j) == 0 {
            j += 1
          }
          // the hyphens ending a word are its own, not those a next
          // fragment starts with (Prawn tokenizes each fragment: `-common`
          // is a token of its own, and a place to break)
          let own = fn(k : Int) { items[k].fragment == items[k - 1].fragment }
          if j < end && kind(j) == 3 && own(j) {
            j += 1
          } else {
            while j < end && kind(j) == 2 && own(j) {
              j += 1
            }
          }
        }
        1 =>
          while j < end && kind(j) == 1 {
            j += 1
          }
        2 => {
          while j < end && kind(j) == 2 {
            j += 1
          }
          while j < end && kind(j) == 0 {
            j += 1
          }
        }
        _ => j += 1
      }
      pos = j
    }
    i = end
  }
  starts
}

///|
pub fn build_items(
  fragments : Array[Fragment],
  ctx : TextContext,
  available? : Double = 1.0e9,
) -> (Array[Item], Array[Face]) {
  let items : Array[Item] = []
  let faces : Array[Face] = []
  for index, fragment in fragments {
    let style = fragment.style
    let (bold, italic) = style.face_style()
    let face = ctx.face(style.family, bold, italic)
    faces.push(face)
    let blank : Item = {
      unit: 0,
      fragment: index,
      fit: 0.0,
      draw: 0.0,
      kern: 0.0,
      hard_break: false,
      anchor: None,
      offset: -1,
    }
    match fragment.anchor {
      Some(name) => {
        items.push({ ..blank, anchor: Some(name), })
        continue
      }
      None => ()
    }
    if style.image >= 0 {
      // an inline image: one placeholder as wide as the image
      let (width, _, _) = (ctx.hooks.image_size)(
        style.image,
        available,
        face.height_pt(style.size),
      )
      items.push({ ..blank, unit: 0x2063, fit: width, draw: width, offset: 0, })
      continue
    }
    let text = fragment.text
    let n = text.length()
    let scale = style.size / 1000.0
    let pad : Item = {
      ..blank,
      unit: pad_unit,
      fit: style.border_offset,
      draw: style.border_offset,
    }
    if style.border_offset > 0.0 && n > 0 {
      items.push(pad)
    }
    for i in 0..<n {
      let unit = text[i].to_int()
      if unit == 0x0A {
        items.push({ ..blank, unit, hard_break: true, offset: i, })
        continue
      }
      // a zero-width space is a break opportunity that draws nothing; the
      // low half of a surrogate pair rides on the high half's advance
      if unit == 0x200B || (unit >= 0xDC00 && unit <= 0xDFFF) {
        items.push({ ..blank, unit, offset: i, })
        continue
      }
      let cp = if unit >= 0xD800 && unit <= 0xDBFF && i + 1 < n {
        0x10000 + ((unit - 0xD800) << 10) + (text[i + 1].to_int() - 0xDC00)
      } else {
        unit
      }
      let kern = if i + 1 < n {
        face.kerning(cp, text[i + 1].to_int()) * scale
      } else {
        0.0
      }
      items.push({
        ..blank,
        unit,
        offset: i,
        fit: face.prawn_width(cp) * scale,
        draw: face.drawn_width(cp) * scale + kern,
        kern,
      })
    }
    if style.border_offset > 0.0 && n > 0 {
      items.push(pad)
    }
  }
  (items, faces)
}

///|
/// Break `fragments` into lines of at most `width` (the first line
/// `first_width`, and with `indent_paragraphs` also each line after a hard
/// break: Prawn's `indent_paragraphs` starts a paragraph there) and place
/// them.
pub fn typeset_lines(
  fragments : Array[Fragment],
  ctx : TextContext,
  width : Double,
  align : Alignment,
  first_width? : Double = width,
  indent_paragraphs? : Bool = false,
  paragraphs? : Bool = false,
) -> Array[Line] {
  typeset_paragraph_lines(
    fragments,
    ctx,
    width,
    align,
    first_width~,
    indent_paragraphs~,
    paragraphs~,
  ).0
}

///|
/// `typeset_lines`, and whether each line starts a paragraph (the first
/// line, and with `indent_paragraphs` each line after a hard break).
fn typeset_paragraph_lines(
  fragments : Array[Fragment],
  ctx : TextContext,
  width : Double,
  align : Alignment,
  first_width? : Double = width,
  indent_paragraphs? : Bool = false,
  paragraphs? : Bool = false,
) -> (Array[Line], Array[Bool]) {
  let fragments = ctx.apply_fallbacks(fragments)
  let (items, faces, ranges) = break_lines(
    fragments,
    ctx,
    width,
    first_width,
    indent_paragraphs~,
  )
  let lines : Array[Line] = []
  let starts : Array[Bool] = []
  for index, range in ranges {
    let (from, to, hard) = range
    let is_last = index == ranges.length() - 1
    let start = index == 0 || (indent_paragraphs && ranges[index - 1].2)
    let limit = if start { first_width } else { width }
    lines.push(
      place_line(
        ctx,
        fragments,
        faces,
        items,
        from,
        to,
        limit,
        align,
        align == Justify && !is_last && !hard,
        hard,
        paragraphs=paragraphs || indent_paragraphs,
      ),
    )
    starts.push(start)
  }
  (lines, starts)
}

///|
/// Break `fragments` into lines: their items (see `build_items`), faces,
/// and each line's item range (start, end, whether a hard break ends it).
fn break_lines(
  fragments : Array[Fragment],
  ctx : TextContext,
  width : Double,
  first_width : Double,
  indent_paragraphs? : Bool = false,
) -> (Array[Item], Array[Face], Array[(Int, Int, Bool)]) {
  let (items, faces) = build_items(fragments, ctx, available=width)
  let n = items.length()
  let starts = token_starts(items)
  // kerning counts towards fitting only inside a token
  for i in 0..<n {
    if i + 1 >= n || !starts[i + 1] {
      items[i].fit += items[i].kern
    }
  }
  let joined = joined_widths(fragments, faces)
  let ranges : Array[(Int, Int, Bool)] = [] // start, end, ended by hard break
  let mut start = 0
  while start <= n {
    if start >= n {
      if ranges.is_empty() || ranges[ranges.length() - 1].2 {
        ranges.push((start, start, false))
      }
      break
    }
    let limit = if ranges.is_empty() ||
      (indent_paragraphs && ranges[ranges.length() - 1].2) {
      first_width
    } else {
      width
    }
    let mut w = 0.0
    // spaces a line starts with are dropped, as Prawn strips the first
    // fragment of each line (anchors in front of them notwithstanding)
    let mut visible = false
    // line numbers take room but make no break opportunity: a word too long
    // for the line after one wraps by character (asciidoctor-pdf's
    // SourceLineWrap)
    let mut content = false
    let mut last_break = -1
    let mut i = start
    let mut end = -1
    let mut hard = false
    while i < n {
      let item = items[i]
      if item.hard_break {
        end = i
        hard = true
        break
      }
      if content && starts[i] {
        last_break = i
      }
      if fragments[item.fragment].style.linenum {
        w += item.fit
        visible = true
        i += 1
        continue
      }
      if is_break_space(item.unit) {
        if !visible {
          // dropped: it becomes a zero-width space, which draws nothing
          items[i] = { ..item, unit: 0x200B, fit: 0.0, draw: 0.0, }
        } else if w + item.fit > limit + 0.0001 {
          // a space that does not fit ends the line before it, as any
          // segment does: it goes to the next line (and is dropped there),
          // so its fragment takes no part in this line's height
          end = i
          break
        } else {
          w += item.fit
          // a space kept after a line number makes the line breakable
          content = true
        }
        i += 1
        continue
      }
      // the last word of a fragment a word joiner follows must fit with
      // the joiner's first word (asciidoctor-pdf's LineWrap)
      let last_of_fragment = i + 1 >= n ||
        items[i + 1].fragment != item.fragment
      let joiner = if last_of_fragment { joined[item.fragment] } else { 0.0 }
      if w + item.fit + joiner > limit + 0.0001 && visible {
        end = if last_break > start {
          pull_back_limit(items, start, last_break, i)
        } else {
          char_wrap_limit(items, starts, start, i, w, limit)
        }
        break
      }
      // a soft hyphen must fit with its word, but takes no room once it has
      // (Prawn's LineWrap takes its width back): only one ending the line
      // prints
      if item.unit != 0xAD {
        w += item.fit
      }
      if item.anchor is None && item.unit != 0x200B {
        visible = true
        content = true
      }
      i += 1
    }
    if end < 0 {
      end = n
    }
    ranges.push((start, end, hard))
    start = if hard { end + 1 } else { end }
    if hard && start == n {
      // a trailing hard break ends the text
      break
    }
  }
  (items, faces, ranges)
}

///|
/// Prawn's first-line box (`text_with_formatted_first_line`): the first
/// line of `first` (the fragments in the first line's style), placed and
/// justified when text follows, and what follows of `rest` (the same
/// fragments in the regular style) from where the next line starts.
fn split_first_line(
  first : Array[Fragment],
  rest : Array[Fragment],
  ctx : TextContext,
  width : Double,
  align : Alignment,
) -> (Line, Array[Fragment]) {
  let (items, faces, ranges) = break_lines(first, ctx, width, width)
  let (from, to, hard) = ranges[0]
  let next = if hard { to + 1 } else { to }
  let remaining : Array[Fragment] = []
  let mut previous = -1
  for k in next..<items.length() {
    let item = items[k]
    if item.fragment == previous {
      continue
    }
    if item.anchor is Some(_) {
      remaining.push(rest[item.fragment])
      previous = item.fragment
    } else if item.offset >= 0 {
      let fragment = rest[item.fragment]
      remaining.push({
        ..fragment,
        text: fragment.text[item.offset:].to_owned(),
      })
      previous = item.fragment
    }
  }
  let justify = align == Justify && !hard && !remaining.is_empty()
  let line = place_line(
    ctx, first, faces, items, from, to, width, align, justify, hard,
  )
  (line, remaining)
}

///|
/// `fragments` set in `style`'s document font style (bold, italic) where
/// their markup does not name one (Prawn's box `:style` option).
fn restyle_fragments(
  fragments : Array[Fragment],
  style : Style,
) -> Array[Fragment] {
  fragments.map(f => {
    ..f,
    style: {
      ..f.style,
      doc_bold: style.doc_bold,
      doc_italic: style.doc_italic,
    },
  })
}

///|
/// For each fragment followed by word joiners (`class="wj"`) and not one
/// itself: the width of the joiners' first word, measured in the
/// fragment's own font (Arranger#preview_joined_string, as LineWrap
/// measures it: the joined text of the following joiners, their NUL
/// placeholders left out, up to its first break character); else 0.
fn joined_widths(
  fragments : Array[Fragment],
  faces : Array[Face],
) -> Array[Double] {
  let widths = Array::make(fragments.length(), 0.0)
  for f in 0..<fragments.length() {
    if fragments[f].style.wj ||
      f + 1 >= fragments.length() ||
      !fragments[f + 1].style.wj {
      continue
    }
    let sb = StringBuilder()
    let mut g = f + 1
    while g < fragments.length() && fragments[g].style.wj {
      if fragments[g].anchor is None {
        sb.write_string(fragments[g].text)
      }
      g += 1
    }
    let text = sb.to_string()
    let face = faces[f]
    let size = fragments[f].style.size
    let mut width = 0.0
    let mut k = 0
    while k < text.length() && !is_break_char(text[k].to_int()) {
      width += face.prawn_width(text[k].to_int())
      if k + 1 < text.length() && !is_break_char(text[k + 1].to_int()) {
        width += face.kerning(text[k].to_int(), text[k + 1].to_int())
      }
      k += 1
    }
    widths[f] = width * size / 1000.0
  }
  widths
}

///|
/// Where a line without a break opportunity ends when its word overflows
/// at `items[i]` (`w` wide before it): Prawn wraps that word by character
/// (`wrap_by_char`), measuring each character on its own, without the
/// kerning its word was measured with, and keeps it while it fits.
fn char_wrap_limit(
  items : Array[Item],
  starts : Array[Bool],
  start : Int,
  i : Int,
  w : Double,
  limit : Double,
) -> Int {
  let n = items.length()
  // the width of an item without the kerning with the next character of
  // its token (see `typeset_lines`)
  let plain = fn(k : Int) {
    if k + 1 < n && !starts[k + 1] {
      items[k].fit - items[k].kern
    } else {
      items[k].fit
    }
  }
  // the segment that overflowed: its token, within its fragment (what
  // came before it in other fragments was measured as it fit)
  let mut token = i
  while token > start &&
        !starts[token] &&
        items[token - 1].fragment == items[i].fragment {
    token -= 1
  }
  let mut acc = w
  for k in token..<i {
    acc -= items[k].fit
  }
  let mut k = token
  while k < n && !items[k].hard_break && acc + plain(k) <= limit {
    acc += plain(k)
    k += 1
  }
  if k <= start {
    i
  } else {
    k
  }
}

///|
/// Prawn's break characters (`LineWrap#break_chars`): whitespace, the
/// zero-width space, the soft hyphen and the hyphen.
fn is_break_char(unit : Int) -> Bool {
  is_whitespace(unit) || unit == 0xAD || unit == 0x2D
}

///|
/// Where a line that overflows at `items[i]` ends, when the word that does
/// not fit starts at `token` (a token start after the line's `start`).
///
/// Prawn wraps fragment by fragment: when not even the first segment of a
/// fragment fits, it moves the last word of the fragment before it to the
/// next line with it (`pull_preceding_fragment_to_join_this_one?`), but no
/// further back. So a word made of several fragments (`(` `iss91v2` `),`)
/// breaks at the start of the last word of the fragment before the one
/// that overflowed, even when the word began in an earlier fragment.
fn pull_back_limit(
  items : Array[Item],
  start : Int,
  token : Int,
  i : Int,
) -> Int {
  let fragment = items[i].fragment
  if items[token].fragment == fragment {
    return token
  }
  // the first item of the overflowing fragment on this line
  let mut first = i
  while first > start && items[first - 1].fragment == fragment {
    first -= 1
  }
  if first <= token {
    return token
  }
  // the last word of the fragment before it
  let previous = items[first - 1].fragment
  let mut word = first
  while word > start &&
        items[word - 1].fragment == previous &&
        !is_break_char(items[word - 1].unit) {
    word -= 1
  }
  @cmp.maximum(word, token)
}

///|
fn place_line(
  ctx : TextContext,
  fragments : Array[Fragment],
  faces : Array[Face],
  items : Array[Item],
  from : Int,
  to : Int,
  limit : Double,
  align : Alignment,
  justify : Bool,
  hard : Bool,
  paragraphs? : Bool = false,
) -> Line {
  // the spaces a line ends with are not part of it, nor are anchors that
  // end it: Prawn's `omit_trailing_whitespace_from_line_width` takes a
  // fragment whose text Ruby's `strip` empties as white space, and
  // asciidoctor-pdf's anchor text is a NUL, which `strip` removes; so is
  // the highlight mark of a source line. But Prawn stops at a line break:
  // only a line that wraps (source_wrap's breaks included) or ends the
  // text loses the spaces and marks it ends with
  let wraps = !hard ||
    paragraphs ||
    (to < items.length() && fragments[items[to].fragment].style.wrap_break)
  let mut visible_end = to
  while visible_end > from &&
        (
          (wraps && is_break_space(items[visible_end - 1].unit)) ||
          items[visible_end - 1].anchor is Some(_) ||
          (wraps && fragments[items[visible_end - 1].fragment].style.line_mark)
        ) {
    visible_end -= 1
  }
  // what Prawn draws of the line: each fragment's text without its
  // zero-width spaces and soft hyphens (`process_text`), but for a soft
  // hyphen that is the last character of a line that wraps (or ends the
  // text), which prints; what is hidden takes no room
  let mut printed_hyphen = -1
  if wraps {
    let mut k = visible_end - 1
    while k >= from &&
          (
            items[k].unit == 0x200B ||
            items[k].unit == pad_unit ||
            items[k].anchor is Some(_)
          ) {
      k -= 1
    }
    if k >= from && items[k].unit == 0xAD {
      printed_hyphen = k
    }
  }
  let hidden = fn(i : Int) {
    items[i].unit == 0x200B || (items[i].unit == 0xAD && i != printed_hyphen)
  }
  // what an item takes as drawn: kerned with the next character drawn of
  // its fragment on the line, as Prawn draws each fragment's text as one
  // string (none after the last, at the end of a fragment or the line)
  let drawn = fn(i : Int) -> Double {
    let item = items[i]
    let mut j = i + 1
    while j < visible_end &&
          items[j].fragment == item.fragment &&
          items[j].anchor is None &&
          hidden(j) {
      j += 1
    }
    if j == i + 1 && j < visible_end && items[j].fragment == item.fragment {
      // the next one, as measured
      item.draw
    } else if j < visible_end &&
      items[j].fragment == item.fragment &&
      items[j].anchor is None &&
      items[j].unit != pad_unit {
      // past hidden ones
      item.draw -
      item.kern +
      faces[item.fragment].kerning(item.unit, items[j].unit) *
      (fragments[item.fragment].style.size / 1000.0)
    } else {
      item.draw - item.kern
    }
  }
  let mut draw_width = 0.0
  let mut fit_width = 0.0
  let mut spaces = 0
  for i in from..<visible_end {
    if hidden(i) {
      continue
    }
    draw_width += drawn(i)
    fit_width += items[i].fit
    if is_break_space(items[i].unit) {
      spaces += 1
    }
  }
  let extra = if justify && spaces > 0 && limit > draw_width {
    (limit - draw_width) / spaces.to_double()
  } else {
    0.0
  }
  let offset = match align {
    Center => (limit - draw_width) / 2.0
    Right => limit - draw_width
    _ => 0.0
  }
  let runs : Array[LineRun] = []
  let anchors : Array[(String, Double)] = []
  let mut x = offset
  let mut i = from
  let mut ascender = 0.0
  let mut descender = 0.0
  let mut height = 0.0
  let images : Array[(Double, Int, Double, Double, Bool, Style, Face)] = []
  let marks : Array[(Double, Style, Face)] = []
  fn measure(fragment : Int) {
    let style = fragments[fragment].style
    let face = faces[fragment]
    let mut a = face.ascender_pt(style.size)
    let d = face.descender_pt(style.size)
    let mut h = face.height_pt(style.size)
    if style.image >= 0 {
      // an image more than one and a half lines tall makes the line as
      // tall as the image, over the text's descender
      let (_, image_h, increased) = (ctx.hooks.image_size)(
        style.image,
        limit,
        h,
      )
      if increased {
        a = image_h - d
        h = image_h
      }
    }
    if a > ascender {
      ascender = a
    }
    if d > descender {
      descender = d
    }
    if h > height {
      height = h
    }
  }

  while i < visible_end {
    let fragment = items[i].fragment
    if items[i].unit == pad_unit {
      x += items[i].draw
      i += 1
      continue
    }
    match items[i].anchor {
      Some(name) => {
        anchors.push((name, x))
        i += 1
        continue
      }
      None => ()
    }
    let style = fragments[fragment].style
    if style.image >= 0 {
      let face = faces[fragment]
      let (w, h, increased) = (ctx.hooks.image_size)(
        style.image,
        limit,
        face.height_pt(style.size),
      )
      images.push((x, style.image, w, h, increased, style, face))
      x += items[i].draw
      measure(fragment)
      i += 1
      continue
    }
    if style.line_mark {
      marks.push((x, style, faces[fragment]))
    }
    let sb = StringBuilder()
    let advances : Array[Double] = []
    let run_x = x
    while i < visible_end &&
          items[i].fragment == fragment &&
          items[i].anchor is None &&
          items[i].unit != pad_unit {
      let item = items[i]
      if !hidden(i) {
        sb.write_char(item.unit.unsafe_to_char())
        let advance = drawn(i) +
          (if is_break_space(item.unit) { extra } else { 0.0 })
        advances.push(advance)
        x += advance
      }
      i += 1
    }
    if advances.length() > 0 {
      runs.push({
        fragment,
        text: sb.to_string(),
        style: fragments[fragment].style,
        face: faces[fragment],
        x: run_x,
        advances,
        width: x - run_x,
      })
      measure(fragment)
    }
  }
  // the anchors and line marks among the trailing white space, where the
  // line's text ends (an empty highlighted source line is painted from the
  // end of its number, not of the blank after it)
  for k in visible_end..<to {
    match items[k].anchor {
      Some(name) => anchors.push((name, x))
      None => {
        let fragment = items[k].fragment
        let style = fragments[fragment].style
        if style.line_mark &&
          (k == visible_end || items[k - 1].fragment != fragment) {
          marks.push((x, style, faces[fragment]))
        }
      }
    }
  }
  // every fragment the line holds counts towards its height, as Prawn's
  // arranger measures each fragment it consumed for the line: spaces that
  // end it or were dropped from its start, anchors (asciidoctor-pdf's
  // placeholder text), and the line break that ends it
  let last = if hard { to + 1 } else { to }
  let mut previous = -1
  for k in from..<@cmp.minimum(last, items.length()) {
    if items[k].fragment != previous {
      previous = items[k].fragment
      measure(previous)
    }
  }
  if runs.is_empty() && height == 0.0 {
    // an empty line takes the metrics of the fragment it sits in
    let fragment = if from < items.length() {
      items[from].fragment
    } else if from > 0 {
      items[from - 1].fragment
    } else {
      -1
    }
    if fragment >= 0 {
      measure(fragment)
    }
  }
  // a link fragment the line holds that draws nothing on it (spaces
  // dropped from its start or left out at its end) still gets its link,
  // zero wide where the fragment sits, as Prawn annotates every fragment
  // of the line
  let empty_links : Array[(Double, Style, Face)] = []
  let held : Array[(Int, Double, Style, Face)] = []
  let mut seen = -1
  let mut position = offset
  for k in from..<to {
    let item = items[k]
    let f = item.fragment
    let style = fragments[f].style
    if f != seen {
      held.push(
        (f, if k < visible_end { position } else { x }, style, faces[f]),
      )
    }
    if f != seen &&
      style.link is Some(_) &&
      style.image < 0 &&
      !runs.iter().any(r => r.fragment == f) {
      empty_links.push(
        (if k < visible_end { position } else { x }, style, faces[f]),
      )
    }
    seen = f
    if k < visible_end && item.anchor is None && !hidden(k) {
      position += drawn(k) +
        (if is_break_space(item.unit) { extra } else { 0.0 })
    }
  }
  {
    runs,
    anchors,
    fit_width,
    ascender,
    descender,
    height,
    empty_links,
    images,
    marks,
    held,
  }
}

///|
/// The first line of `fragments` set `width` wide, and where the text
/// after it starts (a fragment and an offset in its text), if any does.
fn first_line_break(
  fragments : Array[Fragment],
  ctx : TextContext,
  width : Double,
  align : Alignment,
) -> (Line, (Int, Int)?) {
  let (items, faces, ranges) = break_lines(fragments, ctx, width, width)
  let (from, to, hard) = ranges[0]
  let next = if hard { to + 1 } else { to }
  let mut after = None
  for k in next..<items.length() {
    let item = items[k]
    if item.anchor is Some(_) {
      after = Some((item.fragment, 0))
      break
    } else if item.offset >= 0 {
      after = Some((item.fragment, item.offset))
      break
    }
  }
  let justify = align == Justify && !hard && after is Some(_)
  let line = place_line(
    ctx, fragments, faces, items, from, to, width, align, justify, hard,
  )
  (line, after)
}
