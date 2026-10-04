///|
// TrueType fonts (Prawn's `TTF`): families registered by their files
// (`font_families.update`), a file used as a font of its own, and the
// fallback fonts text looks in for what its font lacks. As in Prawn, a
// TrueType font is its file: the catalog has each file read as a face of
// its own, named by the file, read when first used (the catalog is made
// again with it, its registry taking no faces once used).

///|
/// Prawn's `font_families.update(family => { style => file })`: `family`
/// is set in `files` from now on, each the path of a TrueType font (read
/// through the document's `assets` when used).
pub fn Document::font_families_update(
  self : Document,
  family : String,
  files : Array[(FontStyle, String)],
) -> Unit {
  self.families[family] = files
}

///|
/// Prawn's `fallback_fonts`: the fonts (families, standard fonts, files) a
/// character text's font lacks is looked for in, in order.
pub fn Document::fallback_fonts(self : Document, fonts : Array[String]) -> Unit {
  self.fallbacks = fonts
}

///|
fn style_of_flags(flags : (Bool, Bool)) -> FontStyle {
  match flags {
    (false, false) => Normal
    (true, false) => Bold
    (false, true) => Italic
    (true, true) => BoldItalic
  }
}

///|
/// The file of `family` in `style`, when the family is one registered by
/// its files. Raises UnknownFont when the family has no such style.
fn Document::family_file(
  self : Document,
  family : String,
  style : FontStyle,
) -> String? raise PrawnError {
  guard self.families.get(family) is Some(files) else { return None }
  for entry in files {
    if entry.0.flags() == style.flags() {
      return Some(entry.1)
    }
  }
  let name = match style {
    Normal => "normal"
    Bold => "bold"
    Italic => "italic"
    BoldItalic => "bold_italic"
  }
  raise UnknownFont("\{family} (\{name}) is not a known font.")
}

///|
/// The TrueType font in `file`, read unless it is already; Prawn reads a
/// font when it is first used. A file that cannot be read is Prawn's
/// ArgumentError; one not a TrueType font, not yet supported. The face
/// joins the catalog only once the catalog is made with it.
fn Document::load_file(self : Document, file : String) -> Unit raise PrawnError {
  if self.font_files.iter().any(f => f.0 == file) {
    return
  }
  guard (self.assets)(file) is Some(bytes) else {
    raise ArgumentError("\{file} not found")
  }
  if !file.to_lower().has_suffix(".ttf") {
    raise Unsupported("the font \{file} (only TrueType is read yet)")
  }
  let files = [..self.font_files, (file, bytes)]
  let catalog = FontCatalog::load(files.map(f => (f.0, false, false, f.1))) catch {
    e => raise Unsupported("the font \{file}: \{e}")
  }
  self.font_files = files
  self.catalog = catalog
  self.text_context = { catalog, hooks: self.text_context.hooks, }
}

///|
/// The font `name` is in `flags` ready to set text in: a family's face in
/// that style (UnknownFont when it lacks it) or a font file, read as
/// needed; a standard font needs nothing.
fn Document::ensure_font(
  self : Document,
  name : String,
  flags : (Bool, Bool),
) -> Unit raise PrawnError {
  if is_font_file(name) {
    self.load_file(name)
  } else {
    match self.family_file(name, style_of_flags(flags)) {
      Some(file) => self.load_file(file)
      None => ()
    }
  }
}

///|
/// The catalog's face for font `name` in `flags`: a family registered by
/// its files is its file in that style; a file, itself; a standard family,
/// itself in that style. (family, bold, italic) as the catalog keys it.
fn Document::catalog_key(
  self : Document,
  name : String,
  flags : (Bool, Bool),
) -> (String, Bool, Bool) {
  match self.families.get(name) {
    Some(files) => {
      for entry in files {
        if entry.0.flags() == flags {
          return (entry.1, false, false)
        }
      }
      (name, flags.0, flags.1)
    }
    None if is_font_file(name) => (name, false, false)
    None => (name, flags.0, flags.1)
  }
}

///|
/// The face the catalog keys so.
fn Document::face_by_key(self : Document, key : (String, Bool, Bool)) -> Face {
  self.text_context.face(key.0, key.1, key.2)
}

///|
/// Prawn's `glyph_present?`: a standard font has a character it can encode
/// (a line break included); a TrueType font, one its cmap maps.
fn glyph_present(face : Face, cp : Int) -> Bool {
  if face.standard {
    cp < 0x80 || winansi_code_of(cp) is Some(_)
  } else {
    face.has_glyph(cp)
  }
}

///|
/// A fragment's own `:font` and styles (Prawn's fragment hash), which its
/// fallback fonts are looked up with.
fn Document::own_font(
  self : Document,
  style : Style,
) -> (String?, (Bool, Bool)) {
  match self.fragment_meta.get(style.callback) {
    Some(meta) => (meta.font, meta.styles)
    None => (None, (false, false))
  }
}

///|
/// The face font `name` stands for in the fragment's own styles `flags`,
/// found as Prawn's `font(name, style:)` finds it (read as needed); None
/// for the current font as it is (a current font of no family).
fn Document::fallback_face(
  self : Document,
  name : String?,
  flags : (Bool, Bool),
) -> Face raise PrawnError {
  match name {
    None => self.face_by_key(self.font_key)
    Some(name) => {
      let (family, face_flags, _) = self.find_font(name, style_of_flags(flags))
      self.face_by_key(self.catalog_key(family, face_flags))
    }
  }
}

///|
/// Prawn's `find_font_for_this_glyph`: the font character `cp` of a
/// fragment in `style` is set in, by name. The fragment's font (its own
/// `:font`, else the current font's family; None when that has no family)
/// when it has the character, else the first fallback that has it, else
/// the fragment's font, each looked up in the fragment's own styles and
/// read only when the character reaches it. None also when it is the
/// fragment's font and the fragment named none: it keeps its font.
fn Document::glyph_font(
  self : Document,
  style : Style,
  cp : Int,
) -> String? raise PrawnError {
  let (own, flags) = self.own_font(style)
  let fragment_font = match own {
    Some(font) => Some(font)
    None if self.font_family_known => Some(self.family)
    None => None
  }
  let candidates = [..self.fallbacks.map(name => Some(name)), fragment_font]
  let mut chosen = fragment_font
  if !glyph_present(self.fallback_face(fragment_font, flags), cp) {
    for i, candidate in candidates {
      chosen = candidate
      if i == candidates.length() - 1 ||
        glyph_present(self.fallback_face(candidate, flags), cp) {
        break
      }
    }
  }
  if own is None && chosen == fragment_font {
    None
  } else {
    chosen
  }
}

///|
/// The face character `cp` of a fragment in `style` is set in (Prawn's
/// fallback processing).
fn Document::glyph_face(
  self : Document,
  style : Style,
  cp : Int,
) -> Face raise PrawnError {
  match self.glyph_font(style, cp) {
    None => self.face_of(style)
    Some(name) => self.fallback_face(Some(name), self.own_font(style).1)
  }
}

///|
/// Prawn's fallback processing (`process_fallback_fonts`): each fragment
/// split where the font its characters are set in changes; a piece in
/// another font is set in it, in the fragment's own styles, and is drawn
/// in it (callbacks see it current).
fn Document::split_fallbacks(
  self : Document,
  fragments : Array[Fragment],
) -> Array[Fragment] raise PrawnError {
  guard !self.fallbacks.is_empty() else { return fragments }
  let out : Array[Fragment] = []
  for fragment in fragments {
    if fragment.text == "" || fragment.style.image >= 0 {
      out.push(fragment)
      continue
    }
    let flags = self.own_font(fragment.style).1
    let sb = StringBuilder()
    let mut current : String? = None
    let mut first = true
    let flush = (font : String?) => {
      if !sb.is_empty() {
        let style = match font {
          None => fragment.style
          Some(name) => {
            // a piece with a font of its own needs a current font with a
            // family (Prawn's arranger)
            if !self.font_family_known {
              raise BadFontFamily(
                "Prawn::Text::Formatted::Arranger::BadFontFamily",
              )
            }
            let (family, face_flags, known) = self.find_font(
              name,
              style_of_flags(flags),
            )
            let key = self.catalog_key(family, face_flags)
            // its own record: the font it is drawn in, current while it is
            let meta = self.fragment_meta.length()
            match self.fragment_meta.get(fragment.style.callback) {
              Some(m) =>
                self.fragment_meta.push({
                  ..m,
                  font_name: family,
                  font_flags: face_flags,
                  family_known: Some(known),
                  font: Some(name),
                })
              // (a text box's text has none: a record of its own)
              None =>
                self.fragment_meta.push({
                  color_set: false,
                  font_name: family,
                  font_flags: face_flags,
                  styles: flags,
                  font: Some(name),
                  family_known: Some(known),
                  anchor: None,
                  callbacks: [],
                })
            }
            {
              ..fragment.style,
              family: key.0,
              bold: key.1,
              italic: key.2,
              font_set: true,
              callback: meta,
            }
          }
        }
        out.push({ ..fragment, text: sb.to_string(), style, })
        sb.reset()
      }
    }
    for c in fragment.text {
      let font = self.glyph_font(fragment.style, c.to_int())
      if !first && font != current {
        flush(current)
      }
      current = font
      first = false
      sb.write_char(c)
    }
    flush(current)
  }
  out
}

///|
/// Whether a font name is a file (Prawn tells by the extension).
fn is_font_file(name : String) -> Bool {
  let lower = name.to_lower()
  [".ttf", ".otf", ".dfont", ".ttc"].iter().any(ext => lower.has_suffix(ext))
}
