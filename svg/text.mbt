///|
// `<text>`, `<tspan>` and `<tref>` (prawn-svg's `Elements::Text` and
// `Elements::TextComponent`): the text is read depth first, whitespace
// collapsed and put back between pieces, then drawn piece by piece, each
// piece taking the next positions, offsets and rotations its element and
// the elements around it still have.

///|
let generic_font_mapping : Map[String, String] = {
  "serif": "Times-Roman",
  "sans-serif": "Helvetica",
  "cursive": "Times-Roman",
  "fantasy": "Times-Roman",
  "monospace": "Courier",
}

///|
/// prawn-svg's `FontFamilyParser`: the family names of a `font-family`
/// list, quotes and escapes resolved.
fn parse_font_families(text : String) -> Array[String] {
  let fonts : Array[StringBuilder] = []
  let mut in_quote : Char? = None
  let mut in_escape = false
  let mut current : StringBuilder? = None
  for c in text {
    if in_escape {
      in_escape = false
      match current {
        None => {
          let sb = StringBuilder()
          sb.write_char(c)
          fonts.push(sb)
          current = Some(sb)
        }
        Some(sb) => sb.write_char(c)
      }
    } else if c == ',' && in_quote is None {
      current = None
    } else if in_quote == Some(c) {
      in_quote = None
    } else if in_quote is None && (c == '"' || c == '\'') {
      in_quote = Some(c)
    } else if c == '\\' {
      in_escape = true
    } else {
      match current {
        None =>
          if !(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0C}') {
            let sb = StringBuilder()
            sb.write_char(c)
            fonts.push(sb)
            current = Some(sb)
          }
        Some(sb) => sb.write_char(c)
      }
    }
  }
  fonts.map(sb => {
    sb.to_string().trim_end(chars=" \t\n\r\u{0C}\u{00}").to_owned()
  })
}

///|
/// A font the SVG's text is drawn in: its family and style, found among
/// the installed families (prawn-svg's `Font` and `FontRegistry#load`).
fn find_font(
  env : Environment,
  family_list : String,
  weight : String?,
  style : String?,
) -> (String, String)? {
  for name in parse_font_families(family_list) {
    // collapse runs of spaces, lower case
    let sb = StringBuilder()
    let mut space = false
    for c in name {
      if c == ' ' || c == '\t' || c == '\n' {
        if !space {
          sb.write_char(' ')
        }
        space = true
      } else {
        sb.write_char(c)
        space = false
      }
    }
    let lowered = downcase(sb.to_string())
    let installed = fn(n : String) {
      env.families.iter().find_first(f => f.0 == n)
    }
    let name = if installed(lowered) is Some(_) {
      lowered
    } else {
      generic_font_mapping.get(lowered).unwrap_or(lowered)
    }
    // correctly cased
    let name = match
      env.families.iter().find_first(f => downcase(f.0) == downcase(name)) {
      Some(f) => f.0
      None => name
    }
    match installed(name) {
      Some((family, subfamilies)) => {
        let wanted = match (weight, style) {
          (Some("normal"), Some(s)) => s
          (None, None) => "normal"
          (Some(w), Some(s)) => w + "_" + s
          (Some(w), None) => w
          (None, Some(s)) => s
        }
        let subfamily = if subfamilies.contains(wanted) {
          wanted
        } else if subfamilies.contains("normal") {
          "normal"
        } else {
          subfamilies.get(0).unwrap_or("normal")
        }
        return Some((family, subfamily))
      }
      None => ()
    }
  }
  None
}

///|
fn css_font_weight(weight : String?) -> String? {
  match weight {
    Some("100" | "200" | "300") => Some("light")
    Some("400" | "500" | "normal") => Some("normal")
    Some("600") => Some("semibold")
    Some("700" | "bold") => Some("bold")
    Some("800") => Some("extrabold")
    Some("900") => Some("black")
    _ => None
  }
}

///|
/// Process a `<text>` element: read it, then draw it into the parent's
/// calls (a text group). A problem anywhere skips the whole text.
fn Node::process_text(self : Node) -> Unit {
  guard self.source is Some(source) else { return }
  let state = self.state
  state.text = Some(TextState::new(None))
  let root = Node::new(self.doc, TextComponent, Some(source), [], state.dup())
  try {
    root.parse_text_step()
    reintroduce_whitespace(root)
    let group = TextGroup([])
    self.parent_calls.push(group)
    guard group.block() is Some(children) else { return }
    root.apply_text_step(children)
  } catch {
    SkipQuietly => ()
    SkipWarning(message) => self.warn(message)
  }
}

///|
fn collect_printables(node : Node, out : Array[Printable]) -> Unit {
  for item in node.items {
    match item {
      Printed(p) => out.push(p)
      Span(child) => collect_printables(child, out)
    }
  }
}

///|
/// prawn-svg's `reintroduce_trailing_and_leading_whitespace`.
fn reintroduce_whitespace(root : Node) -> Unit {
  let all = []
  collect_printables(root, all)
  let mut first = 0
  let mut last = all.length()
  while last > first && all[last - 1].text == "" {
    last -= 1
  }
  while first < last && all[first].text == "" {
    first += 1
  }
  let printables = all[first:last]
    .iter()
    .filter(p => !(p.text == "" && !p.trailing && !p.leading))
    .collect()
  for i in 0..<(printables.length() - 1) {
    let a = printables[i]
    let b = printables[i + 1]
    if a.text == "" {
      continue
    } else if a.trailing {
      a.text = a.text + " "
    } else if b.leading {
      b.text = " " + b.text
    }
  }
  // the dropped ones draw nothing
  for p in all {
    if !printables.iter().any(q => physical_equal(q, p)) {
      p.text = ""
    }
  }
}

///|
/// Read a text component: attributes, positions, and its children (text
/// and spans), depth first.
fn Node::parse_text_step(self : Node) -> Unit raise Skip {
  self.extract_attributes_and_properties()
  self.parse_xml_space()
  if self.state.inside_clip_path {
    raise SkipWarning("<text> elements are not supported in clip paths")
  }
  guard self.state.text is Some(text) else {
    raise SkipWarning(
      "attempted to <use> an component inside a text element, this is not supported",
    )
  }
  let list = fn(name : String, f : (String) -> Double) {
    split_comma_wsp(self.attr(name).unwrap_or("")).map(f)
  }
  text.x = list("x", v => self.x_pixels(v))
  text.y = list("y", v => self.y_pixels(v))
  text.dx = list("dx", v => self.x_pixels(v))
  text.dy = list("dy", v => self.y_pixels(v))
  text.rotation = list("rotate", ruby_to_f)
  text.text_length = match self.attr("textLength") {
    Some(l) if l.iter().any(c => c >= '0' && c <= '9') => Some(self.x_pixels(l))
    _ => None
  }
  text.length_adjust = self.attr("lengthAdjust")
  text.spacing = match self.state.computed.get("letter-spacing") {
    Some("normal") | None => 0.0
    Some(s) => self.pixels(s)
  }
  let fill = self.state.computed.get("fill") != Some("none")
  let stroke = self.state.computed.get("stroke") != Some("none")
  text.mode = if fill && stroke {
    "fill_stroke"
  } else if fill {
    "fill"
  } else if stroke {
    "stroke"
  } else {
    "invisible"
  }
  self.items = []
  guard self.source is Some(source) else { return }
  // the children, and the element they are the children of
  let (children, parent) = if self.name == "tref" {
    match self.href() {
      Some(h) if h.has_prefix("#") => {
        let id = h.unsafe_substring(start=1, end=h.length())
        match self.doc.elements_by_id.get(id) {
          Some({ name: "text", source: Some(s), .. }) => {
            // the text it refers to must not contain it
            if self.doc.active.contains(s.uid) {
              raise SkipWarning(
                "tref tag has a circular reference to '#\{id}'; skipping tag",
              )
            }
            (s.children, s)
          }
          _ => ([], source)
        }
      }
      _ => ([], source)
    }
  } else {
    (source.children, source)
  }
  self.doc.active.push(parent.uid)
  defer ignore(self.doc.active.pop())
  for child in children {
    match child {
      Text(t) => self.append_text(t)
      CData(_) => ()
      Elem(e) =>
        if e.namespace_uri == "http://www.w3.org/2000/svg" ||
          e.namespace_uri == "" {
          if e.name == "tspan" || e.name == "tref" {
            let state = self.state.dup()
            state.text = Some(TextState::new(self.state.text))
            let span = Node::new(self.doc, TextComponent, Some(e), [], state)
            self.items.push(Span(span))
            span.parse_text_step()
          } else {
            self.warn("Unknown tag '\{e.name}' inside text tag; ignoring")
          }
        }
    }
  }
}

///|
fn Node::append_text(self : Node, raw : String) -> Unit {
  if self.state.preserve_space {
    let text = String::from_iter(
      raw.iter().map(c => if c == '\n' || c == '\t' { ' ' } else { c }),
    )
    self.items.push(Printed({ text, leading: false, trailing: false, }))
  } else {
    let text = String::from_iter(
      raw
      .iter()
      .filter(c => c != '\n')
      .map(c => if c == '\t' { ' ' } else { c }),
    )
    let leading = text.has_prefix(" ")
    let trailing = text.has_suffix(" ")
    // strip, then collapse runs of spaces
    let stripped = strip(text)
    let sb = StringBuilder()
    let mut spaces = 0
    for c in stripped {
      if c == ' ' {
        spaces += 1
      } else {
        if spaces > 0 {
          sb.write_char(' ')
        }
        spaces = 0
        sb.write_char(c)
      }
    }
    self.items.push(Printed({ text: sb.to_string(), leading, trailing, }))
  }
}

///|
/// Draw a text component into `calls`.
fn Node::apply_text_step(self : Node, calls : Array[Call]) -> Unit raise Skip {
  self.base_calls = calls
  self.calls = calls
  self.apply_standard_attributes()
  if self.state.computed.get("display") == Some("none") {
    raise SkipQuietly
  }
  let computed = self.state.computed
  let font = self.select_font()
  match font {
    Some((family, subfamily)) => self.add(Font(family, subfamily))
    None => ()
  }
  guard self.state.text is Some(text) else { return }
  match text.parent {
    Some(parent) => {
      if text.spacing != parent.spacing {
        self.enter(CharacterSpacing(text.spacing, []))
      }
      if text.mode != parent.mode {
        self.enter(TextRenderingMode(text.mode, []))
      }
    }
    None => {
      if text.spacing != 0.0 {
        self.enter(CharacterSpacing(text.spacing, []))
      }
      if text.mode != "fill" {
        self.enter(TextRenderingMode(text.mode, []))
      }
    }
  }
  let size = computed.font_size()
  let anchor = computed.get("text-anchor").unwrap_or("start")
  let baseline = match computed.get("dominant-baseline") {
    Some("auto") | None => None
    b => b
  }
  let decoration = match computed.get("text-decoration") {
    Some("none") | None => None
    d => d
  }
  for item in self.items {
    match item {
      Printed(p) => self.draw_text(p.text, size, anchor, baseline, decoration)
      Span(child) => {
        self.add(Save)
        child.apply_text_step(self.calls)
        self.add(Restore)
      }
    }
  }
  if self.calls.is_empty() {
    self.add(Noop([]))
  }
}

///|
fn Node::select_font(self : Node) -> (String, String)? {
  let computed = self.state.computed
  let family = computed.get("font-family").unwrap_or("sans-serif")
  let style = if computed.get("font-style") == Some("italic") {
    Some("italic")
  } else {
    None
  }
  let weight = css_font_weight(computed.get("font-weight"))
  let env = self.env()
  for name in [family, env.fallback_font] {
    match find_font(env, name, weight, style) {
      Some(font) => return Some(font)
      None => ()
    }
  }
  self.warn(
    "Font family '\{family}' style '\{computed.get("font-style").unwrap_or("normal")}' is not a known font, and the fallback font could not be found.",
  )
  None
}

///|
fn shift(list : Array[Double]) -> Double? {
  if list.is_empty() {
    None
  } else {
    Some(list.remove(0))
  }
}

///|
/// prawn-svg's `apply_text`: draw `text`, one character at a time while
/// positions or rotations remain for it.
fn Node::draw_text(
  self : Node,
  text : String,
  size : Double,
  anchor : String,
  baseline : String?,
  decoration : String?,
) -> Unit {
  guard self.state.text is Some(state) else { return }
  let chars = text.iter().collect()
  let mut index = 0
  while index < chars.length() {
    let mut x : Double? = None
    let mut y : Double? = None
    let mut dx : Double? = None
    let mut dy : Double? = None
    let mut rotate : Double? = None
    let mut remaining = false
    let mut rotation_remaining = false
    let mut list : TextState? = Some(state)
    while list is Some(l) {
      let sx = shift(l.x)
      if x is None {
        x = sx
      }
      let sy = shift(l.y)
      if y is None {
        y = sy
      }
      let sdx = shift(l.dx)
      if dx is None {
        dx = sdx
      }
      let sdy = shift(l.dy)
      if dy is None {
        dy = sdy
      }
      let shifted = if l.rotation.length() > 1 {
        shift(l.rotation)
      } else {
        l.rotation.get(0)
      }
      if shifted is Some(r) && rotate is None {
        rotate = Some(r)
        remaining = remaining ||
          !(l.rotation.length() == 1 && l.rotation[0] == 0.0)
      }
      remaining = remaining ||
        !l.x.is_empty() ||
        !l.y.is_empty() ||
        !l.dx.is_empty() ||
        !l.dy.is_empty() ||
        (rotate is Some(r) && r != 0.0)
      rotation_remaining = rotation_remaining || l.rotation.length() > 1
      list = l.parent
    }
    let options : TextOptions = {
      x,
      y,
      dx: dx.unwrap_or(0.0),
      dy: dy.unwrap_or(0.0),
      size,
      anchor,
      dominant_baseline: baseline,
      decoration,
      rotate: match rotate {
        Some(r) if r != 0.0 => Some(r)
        _ => None
      },
      stretch_to_width: match state.text_length {
        Some(l) if state.length_adjust == Some("spacingAndGlyphs") => Some(l)
        _ => None
      },
      pad_to_width: match state.text_length {
        Some(l) if state.length_adjust != Some("spacingAndGlyphs") => Some(l)
        _ => None
      },
    }
    if remaining {
      self.add(DrawText(chars[index].to_string(), options))
      index += 1
    } else {
      self.add(DrawText(String::from_array(chars[index:]), options))
      // rotations still pending are used up by the characters drawn
      let shift_count = chars.length() - index - 1
      if rotation_remaining && shift_count > 0 {
        let mut list : TextState? = Some(state)
        while list is Some(l) {
          let count = @cmp.minimum(shift_count, l.rotation.length() - 1)
          for _ in 0..<count {
            ignore(l.rotation.remove(0))
          }
          list = l.parent
        }
      }
      break
    }
  }
}
