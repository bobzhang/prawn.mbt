///|
// Prawn's formatted text (`formatted_text`, `text` with `inline_format`):
// fragments with their own styles, and the inline markup Prawn's
// `Text::Formatted::Parser` reads.

///|
/// A fragment of formatted text (Prawn's fragment hash). Unset fields take
/// the document's (font, size, fill colour).
pub(all) struct TextFragment {
  text : String
  bold : Bool
  italic : Bool
  underline : Bool
  strikethrough : Bool
  subscript : Bool
  superscript : Bool
  font : String?
  size : Double?
  /// six hex digits (`"FF0000"`)
  color : String?
  /// a URI the text links to
  link : String?
  /// a named destination the text links to
  anchor : String?
}

///|
/// A plain fragment.
pub fn TextFragment::new(text : String) -> TextFragment {
  {
    text,
    bold: false,
    italic: false,
    underline: false,
    strikethrough: false,
    subscript: false,
    superscript: false,
    font: None,
    size: None,
    color: None,
    link: None,
    anchor: None,
  }
}

///|
/// The tags Prawn's parser knows exactly (`PARSER_REGEX`), in its order.
let exact_tags : Array[String] = [
  "<b>", "</b>", "<i>", "</i>", "<u>", "</u>", "<strikethrough>", "</strikethrough>",
  "<sub>", "</sub>", "<sup>", "</sup>",
]

///|
/// The tag at `i` of `s` (`<link…>`, `<color…>`, `<font…>`, `<a…>` taking
/// anything up to the next `>`), as Prawn's regex alternation finds it.
fn tag_at(s : String, i : Int) -> String? {
  let rest = s[i:].to_owned()
  let open = fn(name : String) -> String? {
    guard rest.has_prefix(name) else { return None }
    match rest.find(">") {
      Some(end) => Some(rest[:end + 1].to_owned())
      None => None
    }
  }
  for t in exact_tags {
    if rest.has_prefix(t) {
      return Some(t)
    }
  }
  match open("<link") {
    Some(t) => return Some(t)
    None => ()
  }
  if rest.has_prefix("</link>") {
    return Some("</link>")
  }
  match open("<color") {
    Some(t) => return Some(t)
    None => ()
  }
  if rest.has_prefix("</color>") {
    return Some("</color>")
  }
  match open("<font") {
    Some(t) => return Some(t)
    None => ()
  }
  if rest.has_prefix("</font>") {
    return Some("</font>")
  }
  for t in ["<strong>", "</strong>", "<em>", "</em>"] {
    if rest.has_prefix(t) {
      return Some(t)
    }
  }
  match open("<a") {
    Some(t) => return Some(t)
    None => ()
  }
  if rest.has_prefix("</a>") {
    return Some("</a>")
  }
  None
}

///|
/// An attribute of a tag, quoted with `"` or `'` (`name="value"`); with
/// `hash`, an optional `#` before the value is dropped.
fn attribute(tag : String, name : String, hash? : Bool = false) -> String? {
  for quote in ["\"", "'"] {
    let start = name + "=" + quote
    match tag.find(start) {
      Some(i) => {
        let mut from = i + start.length()
        if hash && from < tag.length() && tag[from] == '#' {
          from = from + 1
        }
        match tag[from:].find(quote) {
          Some(end) => return Some(tag[from:from + end].to_owned())
          None => ()
        }
      }
      None => ()
    }
  }
  None
}

///|
fn unescape(text : String) -> String {
  text
  .replace_all(old="&lt;", new="<")
  .replace_all(old="&gt;", new=">")
  .replace_all(old="&amp;", new="&")
}

///|
/// Prawn's inline format (`Text::Formatted::Parser.format`): `<b>`/
/// `<strong>`, `<i>`/`<em>`, `<u>`, `<strikethrough>`, `<sub>`, `<sup>`,
/// `<font name size>`, `<color rgb>`, `<link href anchor>`/`<a>`, `<br>`,
/// and `&lt;`, `&gt;`, `&amp;`. A `<` that starts no tag is dropped, as
/// Prawn's scan skips it.
pub fn parse_inline_format(string : String) -> Array[TextFragment] {
  // <br>, <br/> and <br /> are line breaks
  let s = StringBuilder()
  let mut i = 0
  while i < string.length() {
    if string[i:].has_prefix("<br") {
      let mut j = i + 3
      while j < string.length() && is_prawn_space(string[j].unsafe_to_char()) {
        j = j + 1
      }
      if j < string.length() && string[j] == '/' {
        j = j + 1
      }
      if j < string.length() && string[j] == '>' {
        s.write_char('\n')
        i = j + 1
        continue
      }
    }
    s.write_char(string[i].unsafe_to_char())
    i = i + 1
  }
  let text = s.to_string()
  let out : Array[TextFragment] = []
  let styles : Array[String] = []
  let colors : Array[String] = []
  let fonts : Array[String] = []
  let sizes : Array[Double] = []
  let mut link : String? = None
  let mut anchor : String? = None
  let remove = fn(style : String) {
    match styles.search(style) {
      Some(k) => styles.remove(k) |> ignore
      None => ()
    }
  }
  let mut i = 0
  while i < text.length() {
    let c = text[i]
    if c == '\n' {
      out.push(
        fragment_of(
          "\n",
          styles,
          colors.last(),
          fonts.last(),
          sizes.last(),
          link,
          anchor,
        ),
      )
      i = i + 1
      continue
    }
    if c != '<' {
      let mut j = i
      while j < text.length() && text[j] != '<' && text[j] != '\n' {
        j = j + 1
      }
      out.push(
        fragment_of(
          unescape(text[i:j].to_owned()),
          styles,
          colors.last(),
          fonts.last(),
          sizes.last(),
          link,
          anchor,
        ),
      )
      i = j
      continue
    }
    guard tag_at(text, i) is Some(tag) else {
      // a `<` that starts no tag
      i = i + 1
      continue
    }
    i = i + tag.length()
    match tag {
      "<b>" | "<strong>" => styles.push("bold")
      "<i>" | "<em>" => styles.push("italic")
      "<u>" => styles.push("underline")
      "<strikethrough>" => styles.push("strikethrough")
      "<sub>" => styles.push("subscript")
      "<sup>" => styles.push("superscript")
      "</b>" | "</strong>" => remove("bold")
      "</i>" | "</em>" => remove("italic")
      "</u>" => remove("underline")
      "</strikethrough>" => remove("strikethrough")
      "</sub>" => remove("subscript")
      "</sup>" => remove("superscript")
      "</link>" | "</a>" => {
        link = None
        anchor = None
      }
      "</color>" => colors.pop() |> ignore
      // pops what <font> may not have pushed, as Prawn does
      "</font>" => {
        fonts.pop() |> ignore
        sizes.pop() |> ignore
      }
      _ if tag.has_prefix("<link") || tag.has_prefix("<a") => {
        link = attribute(tag, "href")
        anchor = attribute(tag, "anchor")
      }
      _ if tag.has_prefix("<color") =>
        match attribute(tag, "rgb", hash=true) {
          Some(rgb) => colors.push(rgb)
          None => ()
        }
      _ if tag.has_prefix("<font") => {
        match attribute(tag, "name") {
          Some(name) => fonts.push(name)
          None => ()
        }
        match attribute(tag, "size") {
          Some(size) => sizes.push(@string.parse_double(size)) catch { _ => () }
          None => ()
        }
      }
      _ => ()
    }
  }
  out
}

///|
fn fragment_of(
  text : String,
  styles : Array[String],
  color : String?,
  font : String?,
  size : Double?,
  link : String?,
  anchor : String?,
) -> TextFragment {
  {
    text,
    bold: styles.contains("bold"),
    italic: styles.contains("italic"),
    underline: styles.contains("underline"),
    strikethrough: styles.contains("strikethrough"),
    subscript: styles.contains("subscript"),
    superscript: styles.contains("superscript"),
    font,
    size,
    color,
    link,
    anchor,
  }
}

///|
/// A fragment as Flow sets it: its font, size (a sub- or superscript at
/// 0.583 of it, as Prawn's arranger sets them), colour, styles and link.
fn Document::fragment(
  self : Document,
  f : TextFragment,
  size : Double?,
) -> Fragment raise PrawnError {
  let base = self.style(size?)
  let mut size = f.size.unwrap_or(base.size)
  if f.subscript || f.superscript {
    size = size * 0.583
  }
  let color = match f.color {
    Some(hex) => color_of_hex(hex)
    None => base.color
  }
  {
    text: f.text,
    style: {
      ..base,
      family: f.font.unwrap_or(base.family),
      size,
      bold: f.bold,
      italic: f.italic,
      font_set: f.font is Some(_),
      color,
      underline: f.underline,
      strike: f.strikethrough,
      script: if f.superscript {
        1
      } else if f.subscript {
        -1
      } else {
        0
      },
      link: match (f.link, f.anchor) {
        (Some(uri), _) => Some(Uri(uri))
        (None, Some(name)) => Some(Named(name))
        _ => None
      },
    },
    anchor: None,
  }
}

///|
/// Prawn's `formatted_text`: `fragments` flowed from the cursor as `text`
/// flows a string.
pub fn Document::formatted_text(
  self : Document,
  fragments : Array[TextFragment],
  size? : Double,
  align? : Alignment = Left,
  leading? : Double = 0.0,
) -> Unit raise PrawnError {
  let pieces = fragments.filter(f => !f.text.is_empty())
  if pieces.is_empty() {
    self.move_down(leading)
    return
  }
  let set = pieces.map(f => self.fragment(f, size))
  for piece in set {
    self.check(piece.text, piece.style, Some(self.flow.width()))
  }
  let base = self.style(size?)
  self.pending_gap = self.flow.font(base).line_gap_pt(base.size) + leading
  defer {
    self.pending_gap = 0.0
  }
  self.flow.typeset(
    set,
    { leading, padding_top: 0.0, padding_bottom: 0.0, },
    base,
    align~,
  )
  // then the line gap and leading (Prawn's `final_gap`): the last line's,
  // whose largest font sets its gap
  let gap = match self.flow.last_line {
    Some((line, _, _)) => {
      let (a, d, h) = line_extent(line, self.flow.font(base), base.size, false)
      h - a - d
    }
    None => 0.0
  }
  self.move_down(gap + leading)
}

///|
/// Prawn's underline and strikethrough (`draw_fragment_overlay_styles`):
/// lines stroked as `stroke_line` strokes them, in the current stroke
/// colour and line style, 1.25 points below the fragment's baseline and
/// 0.3 of its ascender above it (the baseline a sub- or superscript is
/// raised or dropped to).
fn Document::decorations(
  self : Document,
  x : Double,
  width : Double,
  baseline : Double,
  style : Style,
  face : Face,
) -> Array[@pagelayout.PageItem] {
  let a = face.ascender_pt(style.size)
  let d = face.descender_pt(style.size)
  let rise = match style.script {
    1 => 0.85 * a
    -1 => -d
    _ => 0.0
  }
  let base = baseline - rise
  let gs = self.gs()
  let line = fn(y : Double) -> @pagelayout.PageItem {
    Graphic({
      x_pt: 0.0,
      y_pt: 0.0,
      ops: [
        Path({
          segments: [MoveTo(x, y), LineTo(x + width, y)],
          fill: None,
          fill_rule: NonZero,
          stroke: Some(Solid(gs.stroke)),
          stroke_style: {
            width: if gs.line_width == 0.0 {
              Hairline
            } else {
              Width(gs.line_width)
            },
            cap: gs.cap,
            join: gs.join,
            miter_limit: 10.0,
            dash: gs.dash.copy(),
            dash_phase: gs.dash_phase,
          },
        }),
      ],
    })
  }
  let out = []
  if style.underline {
    out.push(line(base + 1.25))
  }
  if style.strike {
    out.push(line(base - a * 0.3))
  }
  out
}
