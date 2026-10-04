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
  /// a CMYK colour (0 to 100 each), not set yet
  cmyk : Array[Double]?
  /// extra space between characters, not set yet
  character_spacing : Double?
  /// a URI the text links to
  link : String?
  /// a named destination the text links to
  anchor : String?
  /// called as each piece of the fragment is drawn (Prawn's `callback`)
  callbacks : Array[FragmentCallback]
}

///|
/// A piece of a fragment as it is drawn (Prawn's fragment, as callbacks
/// see it), in the coordinates of the bounds: its left side, baseline,
/// width, and its font's top (baseline plus ascender) and bottom
/// (baseline less descender).
pub(all) struct PlacedFragment {
  text : String
  left : Double
  baseline : Double
  width : Double
  height : Double
  top : Double
  bottom : Double
}

///|
/// A fragment callback (Prawn's callback object): `render_behind` before
/// the text is drawn, `render_in_front` after it and its decorations and
/// links. Not called in dry runs (measuring, shrinking, aligning).
pub(all) struct FragmentCallback {
  render_behind : ((PlacedFragment) -> Unit)?
  render_in_front : ((PlacedFragment) -> Unit)?
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
    cmyk: None,
    character_spacing: None,
    link: None,
    anchor: None,
    callbacks: [],
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
pub fn parse_inline_format(
  string : String,
) -> Array[TextFragment] raise PrawnError {
  // <br>, <br/> and <br /> are line breaks
  let s = StringBuilder()
  let mut i = 0
  while i < string.length() {
    if string[i:].has_prefix("<br") {
      let mut j = i + 3
      // Ruby's \s: space, tab, line feed, carriage return, form feed,
      // vertical tab
      while j < string.length() &&
            string[j].unsafe_to_char()
            is (' ' | '\t' | '\n' | '\r' | '\u{0C}' | '\u{0B}') {
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
  let colors : Array[(String?, Array[Double]?)] = []
  let fonts : Array[String] = []
  let sizes : Array[Double] = []
  let spacings : Array[Double] = []
  let mut link : String? = None
  let mut anchor : String? = None
  // every occurrence, as Ruby's Array#delete removes them
  let remove = fn(style : String) { styles.retain(s => s != style) }
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
          spacings.last(),
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
          spacings.last(),
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
        spacings.pop() |> ignore
      }
      // an attribute left out keeps what an outer tag set
      _ if tag.has_prefix("<link") || tag.has_prefix("<a") => {
        match attribute(tag, "href") {
          Some(h) => link = Some(h)
          None => ()
        }
        match attribute(tag, "anchor") {
          Some(a) => anchor = Some(a)
          None => ()
        }
      }
      _ if tag.has_prefix("<color") => {
        match attribute(tag, "rgb", hash=true) {
          Some(rgb) => colors.push((Some(rgb), None))
          None => ()
        }
        // c, m, y and k all given: a CMYK colour
        let parts = ["c", "m", "y", "k"].map(n => attribute(tag, n, hash=true))
        if parts.iter().all(p => p is Some(_)) {
          let values = []
          for p in parts {
            values.push(
              @string.parse_int(p.unwrap()).to_double() catch {
                _ =>
                  raise ArgumentError(
                    "invalid value for Integer(): \{p.unwrap()}",
                  )
              },
            )
          }
          colors.push((None, Some(values)))
        }
      }
      _ if tag.has_prefix("<font") => {
        match attribute(tag, "name") {
          Some(name) => fonts.push(name)
          None => ()
        }
        // Ruby's Float(): a bad number is an ArgumentError
        match attribute(tag, "size") {
          Some(size) => sizes.push(ruby_float(size))
          None => ()
        }
        match attribute(tag, "character_spacing") {
          Some(spacing) => spacings.push(ruby_float(spacing))
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
  color : (String?, Array[Double]?)?,
  font : String?,
  size : Double?,
  spacing : Double?,
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
    color: color.bind(c => c.0),
    cmyk: color.bind(c => c.1),
    character_spacing: spacing,
    link,
    anchor,
    callbacks: [],
  }
}

///|
/// A fragment as Flow sets it: its font, size (a sub- or superscript at
/// 0.583 of it, as Prawn's arranger sets them), colour, styles and link.

///|
/// What Prawn knows of a fragment that its style does not carry: whether
/// it sets its own colour (Prawn then strokes its decorations in it), and
/// the destination it links to besides a URI.
priv struct FragmentMeta {
  color_set : Bool
  anchor : String?
  callbacks : Array[FragmentCallback]
}

///|
/// A standard font's face named directly (`Times-Bold`): its family and
/// whether it is bold and italic.
fn standard_face(name : String) -> (String, Bool, Bool)? {
  // a family name (Courier, Helvetica) is the family, styles and all
  if standard_families.iter().any(entry => entry.0 == name) {
    return None
  }
  for entry in standard_families {
    for i, face in entry.1 {
      if face == name {
        return Some((entry.0, i == 1 || i == 3, i == 2 || i == 3))
      }
    }
  }
  None
}

///|
fn Document::fragment(
  self : Document,
  f : TextFragment,
  size : Double?,
) -> Fragment raise PrawnError {
  if f.cmyk is Some(_) {
    raise Unsupported("CMYK colour")
  }
  if f.character_spacing is Some(_) {
    raise Unsupported("character spacing")
  }
  let base = self.style(size?)
  // a face named directly is that face, whatever the styles say
  let (family, bold, italic, font_set) = match f.font {
    Some(name) =>
      match standard_face(name) {
        Some((family, bold, italic)) => (family, bold, italic, true)
        None => (name, f.bold, f.italic, true)
      }
    None => (base.family, f.bold, f.italic, false)
  }
  let meta = self.fragment_meta.length()
  self.fragment_meta.push({
    color_set: f.color is Some(_),
    anchor: if f.link is Some(_) {
      f.anchor
    } else {
      None
    },
    callbacks: f.callbacks,
  })
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
      family,
      size,
      bold,
      italic,
      font_set,
      callback: meta,
      color,
      underline: f.underline,
      strike: f.strikethrough,
      // a subscript first, as Prawn's `y_offset` checks
      script: if f.subscript {
        -1
      } else if f.superscript {
        1
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
  draw_text_callback? : (String, (Double, Double), Bool) -> Unit,
) -> Unit raise PrawnError {
  // the pieces drawn by the callback instead (text, where, kerning)
  let saved_callback = self.draw_text_callback
  self.draw_text_callback = draw_text_callback
  // the document's position while this text is set (an outer text's
  // is put back after)
  let (outer_y, outer_start) = (self.text_y, self.text_start)
  self.text_y = Some(self.flow.y)
  self.text_start = self.flow.y
  defer {
    self.draw_text_callback = saved_callback
    self.text_y = outer_y
    self.text_start = outer_start
  }
  let pieces = fragments.filter(f => !f.text.is_empty())
  if pieces.is_empty() {
    self.move_down(leading)
    return
  }
  let set = pieces.map(f => self.fragment(f, size))
  // every fragment's encoding first, as Prawn normalizes them all before
  // wrapping
  for piece in set {
    self.check(piece.text, piece.style, None)
  }
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
  // Prawn moves down by what it set from the document's position, which
  // callbacks may have moved (to another page too)
  match self.text_y {
    Some(y) => {
      self.flow.y = self.flow.y + (y - self.text_start)
      self.track()
    }
    None => ()
  }
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
  text : String,
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
  let meta = self.fragment_meta.get(style.callback)
  // the stroke colour current now: a fragment's own colour while it is
  // drawn (`begin_fragment`), or what a callback set
  let stroke = gs.stroke
  let line = fn(y : Double) -> @pagelayout.PageItem {
    Graphic({
      x_pt: 0.0,
      y_pt: 0.0,
      ops: [
        Path({
          segments: [MoveTo(x, y), LineTo(x + width, y)],
          fill: None,
          fill_rule: NonZero,
          stroke: Some(Solid(stroke)),
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
  // a link and an anchor both: the destination's annotation after the
  // URI's, as Prawn draws them
  match meta {
    Some({ anchor: Some(name), .. }) =>
      out.push(
        Link({
          x_pt: x,
          y_pt: base - a,
          w_pt: width,
          h_pt: a + d,
          target: Named(name),
        }),
      )
    _ => ()
  }
  // then the fragment's `render_in_front` callbacks (not in dry runs)
  match meta {
    Some(m) if !self.dry_run && !m.callbacks.is_empty() => {
      let fragment = self.placed(x, width, baseline, style, face, text)
      out.append(
        self.capture(() => {
          for callback in m.callbacks {
            match callback.render_in_front {
              Some(f) => f(fragment)
              None => ()
            }
          }
        }),
      )
    }
    _ => ()
  }
  self.end_fragment()
  out
}

///|
/// Ruby's `Float()` of a string: an optional sign, then digits (with
/// single underscores between them) with an optional fraction (`.5` too)
/// and exponent, or a hex integer (`0x10`), with surrounding whitespace;
/// anything else is an ArgumentError.
fn ruby_float(s : String) -> Double raise PrawnError {
  let bad = ArgumentError("invalid value for Float(): \"\{s}\"")
  let t = s.trim(chars=" \t\n\r\u{0B}\u{0C}").to_owned()
  // hex: [sign] 0x digits
  let unsigned = if t.has_prefix("+") || t.has_prefix("-") {
    t[1:].to_owned()
  } else {
    t
  }
  if unsigned.has_prefix("0x") || unsigned.has_prefix("0X") {
    let hex = unsigned[2:].to_owned()
    if hex.is_empty() ||
      hex.has_prefix("_") ||
      hex.has_suffix("_") ||
      hex.contains("__") {
      raise bad
    }
    let mut value = 0.0
    for c in hex {
      let digit = match c {
        '0'..='9' => c.to_int() - '0'.to_int()
        'a'..='f' => c.to_int() - 'a'.to_int() + 10
        'A'..='F' => c.to_int() - 'A'.to_int() + 10
        '_' => continue
        _ => raise bad
      }
      value = value * 16.0 + digit.to_double()
    }
    return if t.has_prefix("-") { -value } else { value }
  }
  let digits = fn(from : Int) -> Int {
    // how far a run of digits with single underscores between them goes
    let mut i = from
    while i < t.length() &&
          (
            t[i].unsafe_to_char().is_ascii_digit() ||
            (
              t[i] == '_' &&
              i > from &&
              i + 1 < t.length() &&
              t[i + 1].unsafe_to_char().is_ascii_digit()
            )
          ) {
      i = i + 1
    }
    i
  }
  let mut i = 0
  if i < t.length() && (t[i] == '+' || t[i] == '-') {
    i = i + 1
  }
  let start = i
  let int_end = digits(start)
  // no integer part only before a fraction (`.5`)
  if int_end == start && !(start < t.length() && t[start] == '.') {
    raise bad
  }
  i = int_end
  if i < t.length() && t[i] == '.' {
    let frac_end = digits(i + 1)
    // `1.` is 1.0, `.` alone is nothing
    if frac_end == i + 1 && int_end == start {
      raise bad
    }
    i = frac_end
  }
  if i < t.length() && (t[i] == 'e' || t[i] == 'E') {
    let mut j = i + 1
    if j < t.length() && (t[j] == '+' || t[j] == '-') {
      j = j + 1
    }
    let exp_end = digits(j)
    if exp_end == j {
      raise bad
    }
    i = exp_end
  }
  if i != t.length() {
    raise bad
  }
  // in a form parse_double takes: digits on both sides of the point
  let n = t
    .replace_all(old="_", new="")
    .replace_all(old=".e", new=".0e")
    .replace_all(old=".E", new=".0E")
  let n = if n.has_suffix(".") { n + "0" } else { n }
  let n = if n.has_prefix(".") {
    "0" + n
  } else if n.has_prefix("+.") || n.has_prefix("-.") {
    n[:1].to_owned() + "0" + n[1:].to_owned()
  } else {
    n
  }
  @string.parse_double(n) catch {
    _ => raise bad
  }
}

///|
/// A run as Prawn's fragment: in the coordinates of the current bounds,
/// the baseline at the run's rise (a sub- or superscript's).
fn Document::placed(
  self : Document,
  x : Double,
  width : Double,
  baseline : Double,
  style : Style,
  face : Face,
  text : String,
) -> PlacedFragment {
  let a = face.ascender_pt(style.size)
  let d = face.descender_pt(style.size)
  let rise = match style.script {
    1 => 0.85 * a
    -1 => -d
    _ => 0.0
  }
  let box = self.current_box()
  let base = self.flow.page_h() - (baseline - rise) - box.bottom_at(self.y())
  {
    text,
    left: x - box.left,
    baseline: base,
    width,
    height: a + d,
    top: base + a,
    bottom: base - d,
  }
}

///|
/// What goes behind a run: its fragment's `render_behind` callbacks (not in
/// dry runs).
fn Document::underlays(
  self : Document,
  x : Double,
  width : Double,
  baseline : Double,
  style : Style,
  face : Face,
  text : String,
) -> Array[@pagelayout.PageItem] {
  // the fragment's state from here to its overlays (`decorations`)
  self.begin_fragment(style)
  match self.fragment_meta.get(style.callback) {
    Some(meta) if !self.dry_run && !meta.callbacks.is_empty() => {
      let fragment = self.placed(x, width, baseline, style, face, text)
      self.capture(() => {
        for callback in meta.callbacks {
          match callback.render_behind {
            Some(f) => f(fragment)
            None => ()
          }
        }
      })
    }
    _ => []
  }
}

///|
/// A run drawn by the `draw_text_callback` of the text being set, when it
/// has one: the text and where it goes (`at`, in the coordinates of the
/// bounds) with Prawn's default kerning.
fn Document::draw_text_instead(
  self : Document,
  text : String,
  x : Double,
  baseline : Double,
  _style : Style,
) -> Array[@pagelayout.PageItem]? {
  match self.draw_text_callback {
    Some(draw) => {
      // a dry run draws nothing either way
      if self.dry_run {
        return Some([])
      }
      let box = self.current_box()
      let at = (
        x - box.left,
        self.flow.page_h() - baseline - box.bottom_at(self.y()),
      )
      Some(self.capture(() => draw(text, at, true)))
    }
    None => None
  }
}

///|
/// Runs a callback and returns what it drew on the page it started on,
/// taken off that page so the run can put it where Prawn would: behind or
/// in front of the text.
fn Document::capture(
  self : Document,
  body : () -> Unit,
) -> Array[@pagelayout.PageItem] {
  // the page it starts on (its record holds it through insertions)
  let page = self.page()
  let mark = page.items.length()
  // the callback runs at the document's position while a text is set (not
  // where Flow is setting lines), and may move it; Flow then carries on
  // from its own
  let line_y = self.flow.y
  match self.text_y {
    Some(y) => self.flow.y = y
    None => ()
  }
  body()
  if self.text_y is Some(_) {
    self.text_y = Some(self.flow.y)
  }
  self.flow.y = line_y
  let items = page.items
  if mark > items.length() {
    return []
  }
  let drawn = items[mark:].to_owned()
  items.truncate(mark)
  drawn
}

///|
/// The document's state around a fragment being drawn (Prawn's arranger):
/// what to put back when the fragment is done.
priv struct FragmentScope {
  family : String
  size : Double
  fill : @pagelayout.Color
  stroke : @pagelayout.Color
  color_set : Bool
}

///|
/// A run's fragment starts being drawn: the document takes its font and
/// size, and its own colour as fill and stroke colour, for the underlay,
/// text, decorations and callbacks that follow.
fn Document::begin_fragment(self : Document, style : Style) -> Unit {
  let gs = self.gs()
  let color_set = self.fragment_meta.get(style.callback)
    is Some({ color_set: true, .. })
  self.scopes.push({
    family: self.family,
    size: self.size,
    fill: gs.fill,
    stroke: gs.stroke,
    color_set,
  })
  self.family = style.family
  self.size = style.size
  if color_set {
    gs.fill = style.color
    gs.stroke = style.color
  }
}

///|
/// The fragment is drawn: font and size back, and a fragment's own colour
/// taken off again on the page current now (a colour a callback set in a
/// fragment without one stays, as with Prawn's arranger).
fn Document::end_fragment(self : Document) -> Unit {
  guard self.scopes.pop() is Some(scope) else { return }
  self.family = scope.family
  self.size = scope.size
  if scope.color_set {
    let gs = self.gs()
    gs.fill = scope.fill
    gs.stroke = scope.stroke
  }
}
