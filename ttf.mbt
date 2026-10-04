///|
// TrueType fonts (Prawn's `TTF`): families registered by their files
// (`font_families.update`), a file used as a font of its own, and the
// fallback families text looks in for what its font lacks. A face is read
// when it is first used, as Prawn loads it, and the catalog is made again
// with it (its registry takes no faces once used).

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
/// Prawn's `fallback_fonts`: the families a character text's font lacks is
/// looked for in, in order.
pub fn Document::fallback_fonts(
  self : Document,
  families : Array[String],
) -> Unit raise PrawnError {
  self.fallbacks = families
  self.rebuild_catalog(self.font_files)
}

///|
/// The name of the face of `family` in `style`, when the family is one
/// registered by its files: its file (Prawn's TTF font name). Raises
/// UnknownFont when the family has no such style.
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
/// The face of `family` in `style` read from `file`, unless it is already
/// (from that file: a family given another file reads it anew); Prawn
/// reads a font when it is first used. A file that cannot be read is
/// Prawn's ArgumentError; one not a TrueType font, not yet supported. The
/// face joins the catalog only once the catalog is made with it.
fn Document::load_face(
  self : Document,
  family : String,
  style : FontStyle,
  file : String,
) -> Unit raise PrawnError {
  let (bold, italic) = style.flags()
  let same = (f : (String, Bool, Bool, Bytes, String)) => {
    f.0 == family && f.1 == bold && f.2 == italic
  }
  if self.font_files.iter().any(f => same(f) && f.4 == file) {
    return
  }
  guard (self.assets)(file) is Some(bytes) else {
    raise ArgumentError("\{file} not found")
  }
  if !file.to_lower().has_suffix(".ttf") {
    raise Unsupported("the font \{file} (only TrueType is read yet)")
  }
  let files = [
    ..self.font_files.filter(f => !same(f)),
    (family, bold, italic, bytes, file),
  ]
  self.rebuild_catalog(files)
  self.font_files = files
}

///|
/// The catalog made again from `files`, with the fallback families.
fn Document::rebuild_catalog(
  self : Document,
  files : Array[(String, Bool, Bool, Bytes, String)],
) -> Unit raise PrawnError {
  let catalog = FontCatalog::load(
    files.map(f => (f.0, f.1, f.2, f.3)),
    fallbacks=self.fallbacks,
  ) catch {
    e => raise Unsupported("a font: \{e}")
  }
  self.catalog = catalog
  self.text_context = { catalog, hooks: self.text_context.hooks, }
}

///|
/// The face a fallback name stands for in `flags`, read as needed, as
/// Prawn's `font` finds it: a family (in that style), a standard font, a
/// font file of its own; UnknownFont otherwise.
fn Document::fallback_face(
  self : Document,
  name : String,
  flags : (Bool, Bool),
) -> Face raise PrawnError {
  let style = match flags {
    (false, false) => Normal
    (true, false) => Bold
    (false, true) => Italic
    (true, true) => BoldItalic
  }
  let (family, face_flags, _) = self.find_font(name, style)
  self.face_of({
    ..self.style(),
    family,
    bold: face_flags.0,
    italic: face_flags.1,
  })
}

///|
/// The face character `cp` of text in `style` is set in: the style's own,
/// or the first fallback that has it, each fallback read only when the
/// character reaches it (as Prawn looks per character), or the style's own
/// when none has it.
fn Document::char_face(
  self : Document,
  style : Style,
  cp : Int,
) -> Face raise PrawnError {
  let face = self.face_of(style)
  if cp == 0x0A || face.has_glyph(cp) {
    return face
  }
  for name in self.fallbacks {
    let fallback = self.fallback_face(name, style.face_style())
    if fallback.has_glyph(cp) {
      return fallback
    }
  }
  face
}

///|
/// The fallback faces `fragments` need, read before they are set, in the
/// order Prawn reaches them.
fn Document::prepare_fallbacks(
  self : Document,
  fragments : Array[Fragment],
) -> Unit raise PrawnError {
  guard !self.fallbacks.is_empty() else { return }
  for fragment in fragments {
    for c in fragment.text {
      self.char_face(fragment.style, c.to_int()) |> ignore
    }
  }
}

///|
/// The face of `family` in `style` ready to set text in: read, when the
/// family is one registered by its files (UnknownFont when it lacks the
/// style).
fn Document::ensure_style(
  self : Document,
  family : String,
  flags : (Bool, Bool),
) -> Unit raise PrawnError {
  let style = match flags {
    (false, false) => Normal
    (true, false) => Bold
    (false, true) => Italic
    (true, true) => BoldItalic
  }
  match self.family_file(family, style) {
    Some(file) => self.load_face(family, style, file)
    None => ()
  }
}

///|
/// Whether a font name is a file (Prawn tells by the extension).
fn is_font_file(name : String) -> Bool {
  let lower = name.to_lower()
  [".ttf", ".otf", ".dfont", ".ttc"].iter().any(ext => lower.has_suffix(ext))
}
