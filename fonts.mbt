///|
pub fn rgb_hex(value : Int) -> Color {
  Color::rgb((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
}

///|
/// One face of the font catalog, with the metrics Prawn (the layout engine
/// behind Ruby asciidoctor-pdf) derives from it. Prawn works in 1/1000 em
/// and truncates every metric to an integer there; so does this.
pub(all) struct Face {
  metrics : @fonts.FaceMetrics
  /// OS/2 typo metrics (hhea when zero), 1/1000 em, truncated
  ascender : Int
  descender : Int
  line_gap : Int
  /// `kern` table pairs, (left glyph << 16 | right glyph) → 1/1000 em
  kern : Map[Int, Double]
  /// a PDF standard font (Prawn's AFM fonts): its text is WinAnsi (see
  /// `winansi_text`), and its glyphs are WinAnsi codes
  standard : Bool
}

///|
/// Prawn's glyph width in 1/1000 em (truncated), used to break lines as
/// Prawn does.
pub fn Face::prawn_width(self : Face, codepoint : Int) -> Double {
  (self.metrics.advance_pt(codepoint, 1000.0) + 1.0e-9).floor()
}

///|
/// The width the PDF declares for the glyph (`/Widths`, truncated as Prawn
/// writes it: `render_pdf` gets `truncate_widths`), used to place glyphs,
/// so they sit where Prawn draws them and need no per-glyph displacement.
fn Face::drawn_width(self : Face, codepoint : Int) -> Double {
  self.prawn_width(codepoint)
}

///|
/// Kerning between two codepoints, 1/1000 em (negative tightens).
pub fn Face::kerning(self : Face, left : Int, right : Int) -> Double {
  if self.kern.is_empty() {
    return 0.0
  }
  let l = self.metrics.glyph_id(left).unwrap_or(0)
  let r = self.metrics.glyph_id(right).unwrap_or(0)
  self.kern.get((l << 16) | r).unwrap_or(0.0)
}

///|
pub fn Face::ascender_pt(self : Face, size : Double) -> Double {
  self.ascender.to_double() / 1000.0 * size
}

///|
/// Positive depth below the baseline.
pub fn Face::descender_pt(self : Face, size : Double) -> Double {
  -self.descender.to_double() / 1000.0 * size
}

///|
pub fn Face::line_gap_pt(self : Face, size : Double) -> Double {
  self.line_gap.to_double() / 1000.0 * size
}

///|
/// Prawn's `font.height`: ascender − descender + line gap.
pub fn Face::height_pt(self : Face, size : Double) -> Double {
  (self.ascender - self.descender + self.line_gap).to_double() / 1000.0 * size
}

///|
fn read_u16(data : Bytes, offset : Int) -> Int {
  (data[offset].to_int() << 8) | data[offset + 1].to_int()
}

///|
fn read_i16(data : Bytes, offset : Int) -> Int {
  let value = read_u16(data, offset)
  if value >= 0x8000 {
    value - 0x10000
  } else {
    value
  }
}

///|
/// Integer(x) in Ruby: truncation toward zero.
fn truncate(x : Double) -> Int {
  if x < 0.0 {
    -(-x).floor().to_int()
  } else {
    x.floor().to_int()
  }
}

///|
/// Parse the first subtable of a `kern` table when it is format 0: ttfunk,
/// and so Prawn, reads only that one.
fn parse_kern(data : Bytes, scale : Double) -> Map[Int, Double] {
  let pairs : Map[Int, Double] = Map([])
  guard @pdflite.pdf_truetype_table(data, "kern") is Some(table) else {
    return pairs
  }
  let base = table.offset
  // version 0 header: version, nTables; then the first subtable's version,
  // length, coverage (format in the high byte), nPairs and search fields
  guard read_u16(data, base) == 0 && read_u16(data, base + 2) > 0 else {
    return pairs
  }
  let subtable = base + 4
  guard read_u16(data, subtable + 4) >> 8 == 0 else { return pairs }
  let n = read_u16(data, subtable + 6)
  let mut p = subtable + 14
  for _ in 0..<n {
    let left = read_u16(data, p)
    let right = read_u16(data, p + 2)
    pairs[(left << 16) | right] = read_i16(data, p + 4).to_double() * scale
    p += 6
  }
  pairs
}

///|
/// Build a face from a TrueType file, registering it in `registry`: the
/// metrics measured with here and the program the PDF embeds are the same
/// bytes.
fn load_face(
  registry : @fonts.FontRegistry,
  family : String,
  bold : Bool,
  italic : Bool,
  data : Bytes,
) -> Face raise {
  let metrics = registry.register(family, data, bold~, italic~)
  let scale = 1000.0 / metrics.units_per_em.to_double()
  // ttfunk: the OS/2 typo value when present and nonzero, else hhea
  let mut ascent = metrics.ascender
  let mut descent = metrics.descender
  let mut gap = metrics.line_gap
  match @pdflite.pdf_truetype_table(data, "OS/2") {
    Some(os2) => {
      let typo_ascent = read_i16(data, os2.offset + 68)
      let typo_descent = read_i16(data, os2.offset + 70)
      let typo_gap = read_i16(data, os2.offset + 72)
      if typo_ascent != 0 {
        ascent = typo_ascent
      }
      if typo_descent != 0 {
        descent = typo_descent
      }
      if typo_gap != 0 {
        gap = typo_gap
      }
    }
    None => ()
  }
  {
    metrics,
    ascender: truncate(ascent.to_double() * scale),
    descender: truncate(descent.to_double() * scale),
    line_gap: truncate(gap.to_double() * scale),
    kern: parse_kern(data, scale),
    standard: false,
  }
}

///|
/// The font catalog of the theme: family → the four styles, and the
/// pagelayout registry holding them, which the renderer draws with; and
/// the icon sets (`icons=font`), each a font family of its own.
pub struct FontCatalog {
  faces : Map[String, Face]
  registry : @fonts.FontRegistry
  /// icon set (`fas`) → icon name → glyph (see `IconSet`)
  priv icons : Map[String, Map[String, String]]
  /// Font Awesome 4 icon name (`fa-save`) → set and name (`far-save`)
  /// (asciidoctor-pdf's `fa-legacy-mapping.yml`)
  legacy_icons : Map[String, String]
  /// the theme's fallback fonts (`font_fallbacks`), in order
  priv fallbacks : Array[String]
}

///|
/// An icon font of prawn-icon (`data/fonts/<set>/`): the set's name (`fas`,
/// `far`, `fab`, `fi`, `pf`), its TrueType font and its legend, which names
/// each glyph: `name: glyph` lines (`fire: "…"`, under the set's key in
/// prawn-icon's `<set>.yml`; the bundled `@icons.fonts()` have their own
/// tables, `<set>/glyphs.txt`, made from the fonts' projects).
pub(all) struct IconSet {
  name : String
  font : Bytes
  legend : String
}

///|
/// A double-quoted YAML scalar's `\uXXXX` escapes decoded (prawn-icon's
/// `fi.yml` writes its glyphs so).
fn decode_unicode_escapes(value : String) -> String {
  guard value.contains("\\u") else { return value }
  let sb = StringBuilder()
  let chars = value.iter().collect()
  let mut i = 0
  let digit = (c : Char) => {
    match c {
      '0'..='9' => Some(c.to_int() - '0'.to_int())
      'a'..='f' => Some(c.to_int() - 'a'.to_int() + 10)
      'A'..='F' => Some(c.to_int() - 'A'.to_int() + 10)
      _ => None
    }
  }
  while i < chars.length() {
    if chars[i] == '\\' && i + 5 < chars.length() && chars[i + 1] == 'u' {
      let mut code = 0
      let mut valid = true
      for j in (i + 2)..<(i + 6) {
        match digit(chars[j]) {
          Some(d) => code = code * 16 + d
          None => valid = false
        }
      }
      if valid {
        sb.write_char(code.unsafe_to_char())
        i += 6
        continue
      }
    }
    sb.write_char(chars[i])
    i += 1
  }
  sb.to_string()
}

///|
/// The `key: value` lines of a flat YAML map, under its top-level key when
/// it has one (prawn-icon's legends: `fas:` then `  fire: "…"`; the legacy
/// mapping: `fa-save: far-save`). Keys starting with `__` are metadata.
fn parse_flat_yaml(text : String) -> Map[String, String] {
  let map : Map[String, String] = Map([])
  for raw in text.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" || line.has_prefix("#") || line == "---" {
      continue
    }
    guard line.find(": ") is Some(i) else { continue }
    let key = line[:i].to_owned()
    if key.has_prefix("__") {
      continue
    }
    let mut value = line[i + 2:].trim().to_owned()
    if value.length() >= 2 && value.has_prefix("\"") && value.has_suffix("\"") {
      value = decode_unicode_escapes(value[1:value.length() - 1].to_owned())
    } else if value.length() >= 2 &&
      value.has_prefix("'") &&
      value.has_suffix("'") {
      value = value[1:value.length() - 1].to_owned()
    }
    map[key] = value
  }
  map
}

///|
pub fn face_key(family : String, bold : Bool, italic : Bool) -> String {
  "\{family}|\{bold}|\{italic}"
}

///|
/// The file names of the default theme's catalog (asciidoctor-pdf's
/// `data/fonts`): (family, bold, italic, file).
pub fn default_font_files() -> Array[(String, Bool, Bool, String)] {
  [
    ("Noto Serif", false, false, "notoserif-regular-subset.ttf"),
    ("Noto Serif", true, false, "notoserif-bold-subset.ttf"),
    ("Noto Serif", false, true, "notoserif-italic-subset.ttf"),
    ("Noto Serif", true, true, "notoserif-bold_italic-subset.ttf"),
    ("M+ 1mn", false, false, "mplus1mn-regular-subset.ttf"),
    ("M+ 1mn", true, false, "mplus1mn-bold-subset.ttf"),
    ("M+ 1mn", false, true, "mplus1mn-italic-subset.ttf"),
    ("M+ 1mn", true, true, "mplus1mn-bold_italic-subset.ttf"),
  ]
}

///|
/// The icon sets of prawn-icon 3.0.0 (its `data/fonts`): (set, font file,
/// legend file), relative to that directory.
pub fn default_icon_font_files() -> Array[(String, String, String)] {
  [
    ("fab", "fab/fa-brands.ttf", "fab/fab.yml"),
    ("far", "far/fa-regular.ttf", "far/far.yml"),
    ("fas", "fas/fa-solid.ttf", "fas/fas.yml"),
    ("fi", "fi/foundation-icons.ttf", "fi/fi.yml"),
    ("pf", "pf/paymentfont-webfont.ttf", "pf/pf.yml"),
  ]
}

///|
/// Load a catalog from font files: (family, bold, italic, TrueType bytes),
/// with the icon sets `icons=font` draws from, asciidoctor-pdf's mapping of
/// Font Awesome 4 icon names (`fa-legacy-mapping.yml`), and the families a
/// character the text's font lacks is looked for in (`fallbacks`).
pub fn FontCatalog::load(
  files : Array[(String, Bool, Bool, Bytes)],
  icon_sets? : Array[IconSet] = [],
  legacy_icon_mapping? : String = "",
  fallbacks? : Array[String] = [],
) -> FontCatalog raise {
  let faces : Map[String, Face] = Map([])
  let registry = @fonts.FontRegistry::new()
  for file in files {
    let (family, bold, italic, data) = file
    faces[face_key(family, bold, italic)] = load_face(
      registry, family, bold, italic, data,
    )
  }
  let icons : Map[String, Map[String, String]] = Map([])
  for set in icon_sets {
    faces[face_key(set.name, false, false)] = load_face(
      registry,
      set.name,
      false,
      false,
      set.font,
    )
    icons[set.name] = parse_flat_yaml(set.legend)
  }
  // the PDF standard fonts Prawn knows by family, unless the catalog has a
  // family of that name
  for entry in standard_families {
    let (family, names) = entry
    if faces.contains(face_key(family, false, false)) {
      continue
    }
    for i, name in names {
      let (bold, italic) = (i == 1 || i == 3, i >= 2)
      match load_standard_face(registry, family, bold, italic, name) {
        Some(face) => faces[face_key(family, bold, italic)] = face
        None => ()
      }
    }
  }
  // complete: nothing may join it once a document is measured with it
  registry.seal()
  {
    faces,
    registry,
    icons,
    legacy_icons: parse_flat_yaml(legacy_icon_mapping),
    fallbacks: fallbacks.filter(f => faces.contains(face_key(f, false, false))),
  }
}

///|
/// The text of fragments set in a standard font, in WinAnsi (see
/// `winansi_text`).
fn TextContext::apply_winansi(
  self : TextContext,
  fragments : Array[Fragment],
) -> Array[Fragment] {
  if !fragments.iter().any(f => self.is_standard(f.style)) {
    return fragments
  }
  fragments.map(f => {
    // a line mark's zero-width space is no text, and stays
    if f.text != "" &&
      f.style.image < 0 &&
      !f.style.line_mark &&
      self.is_standard(f.style) {
      { ..f, text: winansi_text(f.text), }
    } else {
      f
    }
  })
}

///|
/// Whether a style's face is a standard font.
fn TextContext::is_standard(self : TextContext, style : Style) -> Bool {
  let (bold, italic) = style.face_style()
  self.face(style.family, bold, italic).standard
}

///|
/// Whether the face has a glyph for the character (Prawn's
/// `glyph_present?`).
fn Face::has_glyph(self : Face, codepoint : Int) -> Bool {
  match self.metrics.glyph_id(codepoint) {
    Some(gid) => gid != 0
    None => false
  }
}

///|
/// Prawn's fallback fonts (`process_fallback_fonts`): the characters of a
/// fragment its font lacks are set in the first fallback font that has
/// them (a character none has stays in the fragment's font, where it shows
/// as the .notdef glyph).
fn TextContext::apply_fallbacks(
  self : TextContext,
  fragments : Array[Fragment],
) -> Array[Fragment] {
  let fragments = self.apply_winansi(fragments)
  if self.catalog.fallbacks.is_empty() {
    return fragments
  }
  let out : Array[Fragment] = []
  for fragment in fragments {
    // a line mark stays in its font, as asciidoctor-pdf's placeholder (a
    // NUL) is never looked for in the fallback fonts
    if fragment.text == "" ||
      fragment.style.image >= 0 ||
      fragment.style.line_mark {
      out.push(fragment)
      continue
    }
    let (bold, italic) = fragment.style.face_style()
    let face = self.face(fragment.style.family, bold, italic)
    // the family of each character
    let family_of = (c : Char) => {
      let cp = c.to_int()
      if cp == 0x0A || face.has_glyph(cp) {
        return fragment.style.family
      }
      for f in self.catalog.fallbacks {
        if self.face(f, bold, italic).has_glyph(cp) {
          return f
        }
      }
      fragment.style.family
    }
    let sb = StringBuilder()
    let mut current = ""
    let mut first = true
    let flush = (family : String) => {
      if !sb.is_empty() {
        let style = if family == fragment.style.family {
          fragment.style
        } else {
          { ..fragment.style, family, font_set: true, bold, italic, }
        }
        out.push({ ..fragment, text: sb.to_string(), style, })
        sb.reset()
      }
    }
    for c in fragment.text {
      let family = family_of(c)
      if !first && family != current {
        flush(current)
      }
      current = family
      first = false
      sb.write_char(c)
    }
    flush(current)
  }
  out
}

///|
/// The glyph of icon `name` in icon set `set`, when the catalog has both.
pub fn FontCatalog::icon_glyph(
  self : FontCatalog,
  set : String,
  name : String,
) -> String? {
  self.icons.get(set).bind(glyphs => glyphs.get(name))
}

///|
/// Whether the catalog can draw font icons (it has icon sets).
pub fn FontCatalog::has_icons(self : FontCatalog) -> Bool {
  !self.icons.is_empty()
}

///|
/// The face text in a family neither the catalog nor the base font family
/// has is set in: Prawn's default font (Helvetica) in that style, reported
/// to `unknown_font` (Prawn raises `UnknownFont`, which ends the
/// conversion).
fn TextContext::unknown_face(
  self : TextContext,
  family : String,
  bold : Bool,
  italic : Bool,
) -> Face {
  let style = match (bold, italic) {
    (false, false) => "normal"
    (true, false) => "bold"
    (false, true) => "italic"
    (true, true) => "bold_italic"
  }
  (self.hooks.unknown_font)("\{family} (\{style})")
  match self.catalog.faces.get(face_key("Helvetica", bold, italic)) {
    Some(face) => face
    None =>
      // the standard families are always there, unless the catalog has a
      // Helvetica of its own without that style
      match self.catalog.faces.get(face_key("Helvetica", false, false)) {
        Some(face) => face
        None => self.catalog.faces.values().next().unwrap()
      }
  }
}

///|
pub fn TextContext::face(
  self : TextContext,
  family : String,
  bold : Bool,
  italic : Bool,
) -> Face {
  match self.catalog.faces.get(face_key(family, bold, italic)) {
    Some(face) => face
    None =>
      match self.catalog.faces.get(face_key(family, false, false)) {
        Some(face) => face
        None =>
          match
            self.catalog.faces.get(
              face_key(self.hooks.base_family, bold, italic),
            ) {
            Some(face) => face
            None => self.unknown_face(family, bold, italic)
          }
      }
  }
}

///|
/// The families Prawn knows (`font_families`), with their styles: the
/// catalog's (not the icon sets'), and Prawn's built-in AFM families.
pub fn FontCatalog::svg_families(
  self : FontCatalog,
) -> Array[(String, Array[String])] {
  let families : Array[(String, Array[String])] = []
  for key, _ in self.faces {
    let parts = key.split("|").map(p => p.to_owned()).collect()
    guard parts.length() == 3 else { continue }
    let family = parts[0]
    if self.icons.contains(family) {
      continue
    }
    let style = match (parts[1] == "true", parts[2] == "true") {
      (false, false) => "normal"
      (true, false) => "bold"
      (false, true) => "italic"
      (true, true) => "bold_italic"
    }
    match families.iter().find_first(f => f.0 == family) {
      Some(f) => f.1.push(style)
      None => families.push((family, [style]))
    }
  }
  for afm in ["Courier", "Times-Roman", "Helvetica"] {
    if !families.iter().any(f => f.0 == afm) {
      families.push((afm, ["normal", "bold", "italic", "bold_italic"]))
    }
  }
  families
}
