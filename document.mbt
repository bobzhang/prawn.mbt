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
  catalog : FontCatalog
  /// what text is set with: the fonts
  priv text_context : TextContext
  /// the current font (`font`) and size (`font_size`)
  mut family : String
  mut size : Double
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
  priv mut draw_text_callback : ((String, (Double, Double), Bool) -> Unit)?
  /// what Prawn's warnings (`Kernel#warn`) go to (`on_warning`), and
  /// whether the one about built-in fonts and text beyond ASCII was given:
  /// once per document here; Prawn's flag (`Prawn::Fonts::AFM
  /// .hide_m17n_warning`) lasts the process, which no library state should
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
/// all round). Like Prawn, it starts with a page.
pub fn Document::new(
  size? : (Double, Double) = (612.0, 792.0),
  layout? : String = "portrait",
  margin? : Array[Double] = [36.0],
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
    family: "Helvetica",
    size: 12.0,
    pages: [],
    bbox: margin,
    margin,
    fragment_meta: [],
    dry_run: false,
    draw_text_callback: None,
    scopes: [],
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
fn Document::font(self : Document, style : Style) -> Face {
  let (bold, italic) = style.face_style()
  self.text_context.face(style.family, bold, italic)
}

///|
/// The style text is set in: the current font and size, black.
fn Document::style(self : Document, size? : Double) -> Style {
  {
    family: self.family,
    size: size.unwrap_or(self.size),
    bold: false,
    italic: false,
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
  align? : Alignment = Left,
  leading? : Double = 0.0,
  inline_format? : Bool = false,
  draw_text_callback? : (String, (Double, Double), Bool) -> Unit,
) -> Unit raise PrawnError {
  // set as one plain fragment, or the fragments of its markup
  // (`formatted.mbt`)
  let fragments = if inline_format {
    parse_inline_format(string)
  } else {
    [TextFragment::new(string)]
  }
  self.formatted_text(fragments, size?, align~, leading~, draw_text_callback?)
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
  @pdf.render_pdf(
    self.model,
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
  kerning? : Bool = false,
) -> Double raise PrawnError {
  let style = self.style(size?)
  self.check(string, style, None)
  let face = self.font(style)
  let chars = string.iter().map(c => c.to_int()).to_array()
  let mut width = 0.0
  for i, cp in chars {
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
  width? : Double,
  leading? : Double = 0.0,
) -> Double raise PrawnError {
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
) -> Unit raise PrawnError {
  let face = self.font(style)
  // the whole string is encoded before anything is wrapped
  if face.standard {
    for c in string {
      let cp = c.to_int()
      if cp >= 0x80 && winansi_code_of(cp) is None {
        raise IncompatibleStringEncoding(string)
      }
    }
  }
  guard width is Some(w) else { return }
  let scale = style.size / 1000.0
  for c in string {
    if c != ' ' && c != '\n' && face.prawn_width(c.to_int()) * scale > w {
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
