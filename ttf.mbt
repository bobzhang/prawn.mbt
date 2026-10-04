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
  self.rebuild_catalog()
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
/// The face of `family` in `style` read from `file`, unless it is already;
/// Prawn reads a font when it is first used. A file that cannot be read is
/// Prawn's ArgumentError; one not a TrueType font, not yet supported.
fn Document::load_face(
  self : Document,
  family : String,
  style : FontStyle,
  file : String,
) -> Unit raise PrawnError {
  let (bold, italic) = style.flags()
  if self.font_files
    .iter()
    .any(f => f.0 == family && f.1 == bold && f.2 == italic) {
    return
  }
  guard (self.assets)(file) is Some(bytes) else {
    raise ArgumentError("\{file} not found")
  }
  let lower = file.to_lower()
  if !lower.has_suffix(".ttf") {
    raise Unsupported("the font \{file} (only TrueType is read yet)")
  }
  self.font_files.push((family, bold, italic, bytes))
  self.rebuild_catalog()
}

///|
/// The catalog made again from the faces read so far, with the fallback
/// families (each in the styles text may ask of it, read as needed).
fn Document::rebuild_catalog(self : Document) -> Unit raise PrawnError {
  let catalog = FontCatalog::load(self.font_files, fallbacks=self.fallbacks) catch {
    e => raise Unsupported("a font: \{e}")
  }
  self.catalog = catalog
  self.text_context = { catalog, hooks: self.text_context.hooks, }
}

///|
/// The fallback families' faces in the styles of `fragments`, read before
/// the fragments are set (Prawn looks a character up in the fallback
/// family in the fragment's style).
fn Document::prepare_fallbacks(
  self : Document,
  fragments : Array[Fragment],
) -> Unit raise PrawnError {
  guard !self.fallbacks.is_empty() else { return }
  for family in self.fallbacks {
    for fragment in fragments {
      let style = match fragment.style.face_style() {
        (false, false) => Normal
        (true, false) => Bold
        (false, true) => Italic
        (true, true) => BoldItalic
      }
      // a style the family lacks: Prawn's lookup raises as it is used
      match self.family_file(family, style) {
        Some(file) => self.load_face(family, style, file)
        None => ()
      }
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
