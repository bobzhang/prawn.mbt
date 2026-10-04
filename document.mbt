///|
// Prawn's Document (PLAN.md §4, milestone 1): pages, margins, the cursor
// and text, on pagelayout's page model; lines are broken as `typeset.mbt`
// breaks them. Coordinates in this API are Prawn's: points,
// y up, the cursor measured from the bottom of the bounds.

///|
/// Page sizes Prawn knows by name (`PDF::Core::PageGeometry::SIZES`), in
/// points: the common ones.
let page_sizes : Array[(String, Double, Double)] = [
  ("LETTER", 612.0, 792.0),
  ("LEGAL", 612.0, 1008.0),
  ("A3", 841.89, 1190.55),
  ("A4", 595.28, 841.89),
  ("A5", 419.53, 595.28),
  ("A6", 297.64, 419.53),
  ("EXECUTIVE", 521.86, 756.0),
  ("TABLOID", 792.0, 1224.0),
]

///|
/// The size of a page Prawn names (`"A4"`), in points.
pub fn page_size_named(name : String) -> (Double, Double)? {
  for entry in page_sizes {
    if entry.0 == name {
      return Some((entry.1, entry.2))
    }
  }
  None
}

///|
/// Margins as Prawn takes them (`margin: 36`, `[v, h]`, `[t, h, b]`,
/// `[t, r, b, l]`, CSS order): top, right, bottom, left.
pub fn margins_of(values : Array[Double]) -> (Double, Double, Double, Double) {
  match values {
    [all] => (all, all, all, all)
    [v, h] => (v, h, v, h)
    [t, h, b] => (t, h, b, h)
    [t, r, b, l, ..] => (t, r, b, l)
    [] => (36.0, 36.0, 36.0, 36.0)
  }
}

///|
/// A Prawn document.
pub struct Document {
  /// the pages (pagelayout's page model) and the current one
  priv model : @pagelayout.PageModel
  priv mut page_index : Int
  /// Prawn's `y`: the position, up from the bottom of the current page
  priv mut position : Double
  /// the margins pages are made with: top, right, bottom, left
  priv margins : (Double, Double, Double, Double)
  priv mut catalog : FontCatalog
  /// the font families registered (`font_families_update`): family → its
  /// styles' files; the TrueType faces loaded so far, which the catalog is
  /// made from; the fallback families (`fallback_fonts`); and where files
  /// are read from (`ttf.mbt`)
  priv families : Map[String, Array[(FontStyle, String)]]
  priv mut font_files : Array[(String, Bytes)]
  priv mut fallbacks : Array[String]
  priv assets : (String) -> Bytes?
  /// what text is set with: the fonts
  priv mut text_context : TextContext
  /// the current font (`font`) and size (`font_size`)
  mut family : String
  mut size : Double
  /// the current font's style, bold and italic (a fragment's while it is
  /// drawn)
  priv mut face_style : (Bool, Bool)
  /// whether the current font is a family's (Prawn's `font.family`), not a
  /// font set by its own name
  priv mut font_family_known : Bool
  /// the catalog's face of the current font, as it was found when the font
  /// was set (Prawn keeps the font object until another is set)
  priv mut font_key : (String, Bool, Bool)
  /// each page's record (`page.mbt`), as the model's pages are ordered
  priv pages : Array[PageState]
  /// the current bounding box (Prawn's `@bounding_box`) and the current
  /// page's margin box (`bounds.mbt`)
  priv mut bbox : Box
  priv mut margin : Box
  /// what Prawn knows of each fragment set that its style does not carry
  /// (`formatted.mbt`), by the style's `callback` index
  priv fragment_meta : Array[FragmentMeta]
  /// during a dry run (measuring, shrinking, aligning): callbacks are not
  /// called
  priv mut dry_run : Bool
  /// during a `draw_text_callback` text: what draws its pieces instead
  /// the fragments being drawn, innermost last: text set from inside a
  /// callback nests (`formatted.mbt`)
  priv scopes : Array[FragmentScope]
  priv mut draw_text_callback : ((String, (Double, Double), Bool) -> Unit raise PrawnError)?
  /// what Prawn's warnings (`Kernel#warn`) go to (`on_warning`), and
  /// whether the one about built-in fonts and text beyond ASCII was given:
  /// once per document here; Prawn's flag (`Prawn::Fonts::AFM
  /// .hide_m17n_warning`) lasts the process, which no library state should
  /// the leading text is set with when none is given (`default_leading`)
  priv mut default_leading : Double
  priv mut warn : (String) -> Unit
  priv mut m17n_warned : Bool
}

///|
fn oriented(size : (Double, Double), layout : String) -> (Double, Double) {
  if layout == "landscape" {
    (size.1, size.0)
  } else {
    size
  }
}

///|
/// A document with pages `size` (points; Prawn's default is LETTER) in
/// `layout` ("portrait" or "landscape") with `margin` (Prawn's default 36
/// all round). Font files are read through `assets`, given a path as it
/// was named (none by default). Like Prawn, it starts with a page.
pub fn Document::new(
  size? : (Double, Double) = (612.0, 792.0),
  layout? : String = "portrait",
  margin? : Array[Double] = [36.0],
  assets? : (String) -> Bytes? = _ => None,
) -> Document raise {
  let (w, h) = oriented(size, layout)
  let (top, right, bottom, left) = margins_of(margin)
  let catalog = FontCatalog::load([])
  // the margin box until the first page has its own
  let margin : Box = {
    left,
    top: h - top,
    width: w - left - right,
    height: Some(h - top - bottom),
    stretched: 0.0,
    parent: None,
    columns: None,
    total_left: 0.0,
    total_right: 0.0,
  }
  let doc = {
    model: @pagelayout.PageModel::new(),
    page_index: -1,
    position: 0.0,
    margins: (top, right, bottom, left),
    catalog,
    text_context: { catalog, hooks: Hooks::new(), },
    families: Map([]),
    font_files: [],
    fallbacks: [],
    assets,
    family: "Helvetica",
    face_style: (false, false),
    font_family_known: true,
    font_key: ("Helvetica", false, false),
    size: 12.0,
    pages: [],
    bbox: margin,
    margin,
    fragment_meta: [],
    dry_run: false,
    draw_text_callback: None,
    scopes: [],
    default_leading: 0.0,
    warn: _ => (),
    m17n_warned: false,
  }
  doc.make_page((w, h), (size, layout))
  doc.page_changed()
  doc
}

///|
/// A new page like the current one (what a page break makes).
fn Document::new_page(self : Document) -> Unit {
  self.start_new_page()
}

///|
/// Where Prawn's warnings go (Ruby's `Kernel#warn`): `handler` gets each
/// message. By default they go nowhere.
pub fn Document::on_warning(
  self : Document,
  handler : (String) -> Unit,
) -> Unit {
  self.warn = handler
}

///|
/// The face `style` is set in.
fn Document::face_of(self : Document, style : Style) -> Face {
  let (bold, italic) = style.face_style()
  self.text_context.face(style.family, bold, italic)
}

///|
/// The style text is set in: the current font and size, black.
fn Document::style(self : Document, size? : Double) -> Style {
  // the catalog's face of the current font (a TrueType one is its file)
  let (family, bold, italic) = self.font_key
  {
    family,
    size: size.unwrap_or(self.size),
    bold,
    italic,
    color: self.gs().fill,
    link: None,
    background: None,
    script: 0,
    border_offset: 0.0,
    underline: false,
    strike: false,
    wj: false,
    image: -1,
    callback: -1,
    doc_bold: false,
    doc_italic: false,
    font_set: false,
    text_transform: None,
    code_background: None,
    linenum: false,
    line_mark: false,
    wrap_break: false,
  }
}

///|
/// Prawn's `text`: `string` flowed from the cursor within the bounds,
/// across pages as needed; the cursor ends below it.
pub fn Document::text(
  self : Document,
  string : String,
  size? : Double,
  style? : FontStyle,
  align? : Alignment = Left,
  leading? : Double,
  inline_format? : Bool = false,
  draw_text_callback? : (String, (Double, Double), Bool) -> Unit raise PrawnError,
) -> Unit raise PrawnError {
  // the current font in `style` while this is set (Prawn's `:style`, which
  // its boxes apply and undo)
  let saved_font = self.apply_style(
    style,
    BadFontFamily("PDF::Core::Text::BadFontFamily"),
  )
  defer self.restore_style(saved_font)
  // set as one plain fragment, or the fragments of its markup
  // (`formatted.mbt`)
  let fragments = if inline_format {
    parse_inline_format(string)
  } else {
    [TextFragment::new(string)]
  }
  self.formatted_text(fragments, size?, align~, leading?, draw_text_callback?)
}

///|
/// Prawn's `move_down`.
pub fn Document::move_down(self : Document, amount : Double) -> Unit {
  self.set_y(self.y() - amount)
}

///|
/// Prawn's `cursor`: how far the current position is above the bottom of
/// the bounds (always 0 in a stretchy box, whose bottom is the position).
pub fn Document::cursor(self : Document) -> Double {
  let box = self.current_box()
  let y = self.y()
  y - (box.top - box.height_at(y))
}

///|
/// Prawn's `page_number` (from 1).
pub fn Document::page_number(self : Document) -> Int {
  self.page_index + 1
}

///|
/// Prawn's `page_count`.
pub fn Document::page_count(self : Document) -> Int {
  self.model.pages.length()
}

///|
/// Prawn's `start_new_page`.
pub fn Document::start_new_page(
  self : Document,
  layout? : String,
  size? : (Double, Double),
) -> Unit {
  let before = self.page().geometry
  let after = (size.unwrap_or(before.0), layout.unwrap_or(before.1))
  self.make_page(oriented(after.0, after.1), after)
  // a page of another size or layout: content goes in its margin box
  self.page_changed(size_changed=after != before)
}

///|
/// Prawn's `font` (without a block): the family text is set in from now
/// on.
pub fn Document::set_font(self : Document, family : String) -> Unit {
  self.family = family
}

///|
/// Prawn's `font_size=`.
pub fn Document::set_font_size(self : Document, size : Double) -> Unit {
  self.size = size
}

///|
/// The PDF.
pub fn Document::render(self : Document) -> Bytes raise {
  // pdf-core's finalize: on each page in turn (Prawn's render goes to
  // each), every graphics state left on its stack is restored, each a Q
  for i in 0..<self.pages.length() {
    self.go_to_page(i + 1)
    let page = self.page()
    while page.stack.pop() is Some(_) {
      page.restore()
    }
  }
  let pages = self.model.pages.mapi((i, page) => {
    ..page,
    items: self.pages[i].nested(),
  })
  @pdf.render_pdf(
    { fonts: self.model.fonts, pages, },
    options=@pdf.RenderOptions::new(
      fonts=self.catalog.registry,
      truncate_widths=true,
      // a character the font lacks is drawn as its .notdef glyph and kept
      // in the text, as Prawn does
      notdef_text=true,
    ),
  )
}

///|
/// Prawn's `width_of`: how wide `string` is set in the current font at
/// `size` (the current font size), with the font's kerning only when
/// `kerning` asks for it (Prawn does not apply the document's default
/// here).
pub fn Document::width_of(
  self : Document,
  string : String,
  size? : Double,
  style? : FontStyle,
  kerning? : Bool = false,
) -> Double raise PrawnError {
  // the current font in `style` while this is measured (Prawn's `:style`)
  let saved_font = self.apply_style(style, UnknownFont(" is not a known font."))
  defer self.restore_style(saved_font)
  let style = self.style(size?)
  self.check(string, style, None, fallbacks=false)
  let face = self.face_of(style)
  let chars = string.iter().map(c => c.to_int()).to_array()
  let mut width = 0.0
  for i, cp in chars {
    // a TrueType font gives a newline no width (Prawn's TTF does so)
    if cp == 0x0A && !face.standard {
      continue
    }
    width += face.prawn_width(cp)
    if kerning && i + 1 < chars.length() {
      width += face.kerning(cp, chars[i + 1])
    }
  }
  // as Prawn scales: by size / 1000
  width * (style.size / 1000.0)
}

///|
/// Prawn's `height_of`: how tall `string` would be set by `text` in boxes
/// `width` wide (the bounds' width), with the line gap and leading after
/// it (Prawn's final gap).
pub fn Document::height_of(
  self : Document,
  string : String,
  size? : Double,
  style? : FontStyle,
  width? : Double,
  leading? : Double,
) -> Double raise PrawnError {
  // the current font in `style` while this is set (Prawn's `:style`, which
  // its boxes apply and undo)
  let saved_font = self.apply_style(
    style,
    BadFontFamily("PDF::Core::Text::BadFontFamily"),
  )
  defer self.restore_style(saved_font)
  // the document's default leading unless given (Prawn's `default_leading`)
  let leading = leading.unwrap_or(self.default_leading)
  // an empty box: its final gap is the leading alone
  if string.is_empty() {
    return leading
  }
  let style = self.style(size?)
  self.check(string, style, Some(width.unwrap_or(self.bbox.side().1)))
  // Prawn's `height_of_formatted`: a box too tall to fill, set as a dry
  // run, and its final gap
  let (_, printed, gap) = self.set_box(
    [{ text: string, style, anchor: None, }],
    style,
    (0.0, 0.0),
    width.unwrap_or(self.bbox.side().1),
    1.0e8,
    Left,
    leading,
    dry_run=true,
  )
  printed + gap + leading
}

///|
/// What Prawn refuses before setting `string` in `style`: characters a
/// standard font cannot encode (Windows-1252), and, given the `width`
/// lines are set in, a character too wide for it (the line wrap cannot
/// fit even one).
fn Document::check(
  self : Document,
  string : String,
  style : Style,
  width : Double?,
  fallbacks? : Bool = true,
) -> Unit raise PrawnError {
  let face = self.face_of(style)
  // each character in the font it is set in: its own, or the first
  // fallback that has it (Prawn splits the text across them before it
  // encodes it; `width_of` and `draw_text` do not)
  let face_for = fn(cp : Int) raise PrawnError {
    if fallbacks && !self.fallbacks.is_empty() {
      self.glyph_face(style, cp)
    } else {
      face
    }
  }
  // the whole string is encoded before anything is wrapped
  for c in string {
    let cp = c.to_int()
    if face_for(cp).standard && cp >= 0x80 && winansi_code_of(cp) is None {
      raise IncompatibleStringEncoding(string)
    }
  }
  guard width is Some(w) else { return }
  let scale = style.size / 1000.0
  for c in string {
    if c != ' ' &&
      c != '\n' &&
      face_for(c.to_int()).prawn_width(c.to_int()) * scale > w {
      raise CannotFit
    }
  }
}

///|
/// Prawn's `go_to_page` (from 1): back to an existing page, at the top of
/// its margin box.
pub fn Document::go_to_page(self : Document, number : Int) -> Unit {
  self.page_index = number - 1
  self.page_changed()
}

///|
/// Prawn's `default_leading=`: the leading text is set with when none is
/// given.
pub fn Document::set_default_leading(self : Document, leading : Double) -> Unit {
  self.default_leading = leading
}

///|
/// Prawn's `default_leading` (without a value).
pub fn Document::default_leading(self : Document) -> Double {
  self.default_leading
}

///|
/// Prawn's `move_up`.
pub fn Document::move_up(self : Document, amount : Double) -> Unit {
  self.move_down(-amount)
}

///|
/// Prawn's `move_cursor_to`: the cursor at `cursor` points above the bottom
/// of the bounds (as they are before the move).
pub fn Document::move_cursor_to(self : Document, cursor : Double) -> Unit {
  let box = self.current_box()
  let y = self.y()
  self.set_y(cursor + (box.top - box.height_at(y)))
}

///|
/// Prawn's `pad_top`: down by `amount`, then `body`.
pub fn Document::pad_top(
  self : Document,
  amount : Double,
  body : () -> Unit raise,
) -> Unit raise {
  self.move_down(amount)
  body()
}

///|
/// Prawn's `pad_bottom`: `body`, then down by `amount`.
pub fn Document::pad_bottom(
  self : Document,
  amount : Double,
  body : () -> Unit raise,
) -> Unit raise {
  body()
  self.move_down(amount)
}

///|
/// Prawn's `pad`: down by `amount` before and after `body`.
pub fn Document::pad(
  self : Document,
  amount : Double,
  body : () -> Unit raise,
) -> Unit raise {
  self.move_down(amount)
  body()
  self.move_down(amount)
}
