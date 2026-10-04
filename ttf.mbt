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
/// The face character `cp` of text in `style` is set in, as Prawn's
/// fallback processing finds it: the style's own font when it has the
/// character, else the first fallback that has it, each found as `font`
/// finds it in the fragment's own styles `styles` (read only when a
/// character reaches it), else the style's own.
fn Document::char_key(
  self : Document,
  style : Style,
  styles : (Bool, Bool),
  cp : Int,
) -> (String, Bool, Bool) raise PrawnError {
  let own = (style.family, style.bold, style.italic)
  if cp == 0x0A || self.face_by_key(own).has_glyph(cp) {
    return own
  }
  for name in self.fallbacks {
    let (family, flags, _) = self.find_font(name, style_of_flags(styles))
    let key = self.catalog_key(family, flags)
    if self.face_by_key(key).has_glyph(cp) {
      return key
    }
  }
  own
}

///|
/// The styles a fragment asks for itself (Prawn's fragment `styles`, which
/// its fallback fonts are found in).
fn Document::own_styles(self : Document, style : Style) -> (Bool, Bool) {
  match self.fragment_meta.get(style.callback) {
    Some(meta) => meta.styles
    None => (false, false)
  }
}

///|
/// Prawn's fallback processing (`process_fallback_fonts`): each fragment
/// split where the font its characters are set in changes, a piece in a
/// fallback font set in it.
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
    let styles = self.own_styles(fragment.style)
    let sb = StringBuilder()
    let mut current = (
      fragment.style.family,
      fragment.style.bold,
      fragment.style.italic,
    )
    let flush = (key : (String, Bool, Bool)) => {
      if !sb.is_empty() {
        let own = key ==
          (fragment.style.family, fragment.style.bold, fragment.style.italic)
        let style = if own {
          fragment.style
        } else {
          {
            ..fragment.style,
            family: key.0,
            bold: key.1,
            italic: key.2,
            font_set: true,
          }
        }
        out.push({ ..fragment, text: sb.to_string(), style, })
        sb.reset()
      }
    }
    for c in fragment.text {
      let key = self.char_key(fragment.style, styles, c.to_int())
      if key != current {
        flush(current)
        current = key
      }
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
