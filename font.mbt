///|
// Prawn's current font (`font.rb`): a family in a style at a size, set by
// `font` and `font_size` and looked up as Prawn's `find_font` does.

///|
/// A style of a font family (Prawn's `:normal`, `:bold`, `:italic`,
/// `:bold_italic`).
pub(all) enum FontStyle {
  Normal
  Bold
  Italic
  BoldItalic
}

///|
fn FontStyle::flags(self : FontStyle) -> (Bool, Bool) {
  match self {
    Normal => (false, false)
    Bold => (true, false)
    Italic => (false, true)
    BoldItalic => (true, true)
  }
}

///|
/// Prawn's `font(name, style:, size:)`: the font text is set in from now on
/// (within `body` only, when given), `name` being a family (in `style`, by
/// default its normal one) or a font of its own (a standard font's name,
/// such as `Times-Bold`). Raises UnknownFont for a name Prawn does not know.
pub fn Document::font(
  self : Document,
  name : String,
  style? : FontStyle = Normal,
  size? : Double,
  body? : () -> Unit raise,
) -> Unit raise {
  let (family, face_style, known) = self.find_font(name, style)
  match body {
    None => {
      self.family = family
      self.face_style = face_style
      self.font_family_known = known
      self.size = size.unwrap_or(self.size)
    }
    Some(body) => {
      // Prawn's `save_font`, which restores whatever happens
      let saved = (
        self.family,
        self.face_style,
        self.size,
        self.font_family_known,
      )
      defer {
        self.family = saved.0
        self.face_style = saved.1
        self.size = saved.2
        self.font_family_known = saved.3
      }
      self.family = family
      self.face_style = face_style
      self.font_family_known = known
      self.size = size.unwrap_or(self.size)
      body()
    }
  }
}

///|
/// Prawn's `find_font`: a family the document knows, in `style`; else a
/// standard font by its own name.
fn Document::find_font(
  self : Document,
  name : String,
  style : FontStyle,
) -> (String, (Bool, Bool), Bool) raise PrawnError {
  // a family registered by its files, in `style` (read when first used)
  if self.families.contains(name) {
    self.ensure_font(name, style.flags())
    return (name, style.flags(), true)
  }
  if standard_families.iter().any(entry => entry.0 == name) {
    return (name, style.flags(), true)
  }
  // Prawn's other built-in fonts, which pagelayout does not draw yet
  if name == "Symbol" || name == "ZapfDingbats" {
    raise Unsupported("the \{name} font")
  }
  // a face by its own name: drawn in that face, but of no family
  match standard_face(name) {
    Some((family, bold, italic)) => (family, (bold, italic), false)
    // a font file of its own: Prawn's TTF font of no family, named by its
    // path
    None if is_font_file(name) => {
      self.load_file(name)
      (name, (false, false), false)
    }
    None => raise UnknownFont("\{name} is not a known font.")
  }
}

///|
/// Prawn's `font_size` (without a size): the size text is set at.
pub fn Document::font_size(self : Document) -> Double {
  self.size
}

///|
/// Prawn's `font_size(points) { … }`: `body` with text set at `points`,
/// then back to the size before (only when `body` returns: Prawn has no
/// `ensure` here).
pub fn Document::with_font_size(
  self : Document,
  points : Double,
  body : () -> Unit raise,
) -> Unit raise {
  let before = self.size
  self.size = points
  body()
  self.size = before
}

///|
/// The current font's name (Prawn's `font.name`): a standard font's own
/// name (`Times-Bold`).
pub fn Document::font_name(self : Document) -> String {
  let (bold, italic) = self.face_style
  // a TrueType font: its file
  let key = self.catalog_key(self.family, (bold, italic))
  if is_font_file(key.0) {
    return key.0
  }
  for entry in standard_families {
    if entry.0 == self.family {
      let index = (if bold { 1 } else { 0 }) + (if italic { 2 } else { 0 })
      return entry.1.get(index).unwrap_or(entry.1[0])
    }
  }
  self.family
}

///|
/// The Ruby class of the current font (Prawn's `font.class`): AFM for a
/// standard font, TTF for one read from a file.
pub fn Document::font_class(self : Document) -> String {
  let (bold, italic) = self.face_style
  if self.face_of({ ..self.style(), bold, italic, }).standard {
    "Prawn::Fonts::AFM"
  } else {
    "Prawn::Fonts::TTF"
  }
}
