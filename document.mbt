///|
// Prawn's Document (PLAN.md §4, milestone 1): pages, margins, the cursor
// and text, on top of `Flow`. Coordinates in this API are Prawn's: points,
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
  flow : Flow
  catalog : FontCatalog
  /// the current font (`font`) and size (`font_size`)
  mut family : String
  mut size : Double
  /// the page size as given and the layout new pages take (Prawn keeps
  /// them apart: a landscape page reverses the size, whatever its shape)
  mut page_size : (Double, Double)
  mut layout : String
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
  let flow = Flow::new(catalog, {
    width: w,
    height: h,
    margin_top: top,
    margin_right: right,
    margin_bottom: bottom,
    margin_left: left,
  })
  flow.start_new_page(size=(w, h))
  { flow, catalog, family: "Helvetica", size: 12.0, page_size: size, layout, }
}

///|
/// The style text is set in: the current font and size, black.
fn Document::style(self : Document, size? : Double) -> Style {
  {
    family: self.family,
    size: size.unwrap_or(self.size),
    bold: false,
    italic: false,
    color: @pagelayout.Color::rgb(0, 0, 0),
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
) -> Unit {
  // nothing to set: Prawn moves nothing either
  if string.is_empty() {
    return
  }
  let style = self.style(size?)
  self.flow.typeset(
    [{ text: string, style, anchor: None, }],
    // after the text box, the line gap and leading (`final_gap`, Prawn's
    // default)
    {
      leading,
      padding_top: 0.0,
      padding_bottom: self.flow.font(style).line_gap_pt(style.size) + leading,
    },
    style,
    align~,
  )
}

///|
/// Prawn's `move_down`.
pub fn Document::move_down(self : Document, amount : Double) -> Unit {
  self.flow.move_down(amount)
}

///|
/// Prawn's `cursor`: how far the current position is above the bottom of
/// the bounds.
pub fn Document::cursor(self : Document) -> Double {
  self.flow.cursor()
}

///|
/// Prawn's `page_number` (from 1).
pub fn Document::page_number(self : Document) -> Int {
  self.flow.page + 1
}

///|
/// Prawn's `page_count`.
pub fn Document::page_count(self : Document) -> Int {
  self.flow.model.pages.length()
}

///|
/// Prawn's `start_new_page`.
pub fn Document::start_new_page(
  self : Document,
  layout? : String,
  size? : (Double, Double),
) -> Unit {
  self.page_size = size.unwrap_or(self.page_size)
  self.layout = layout.unwrap_or(self.layout)
  self.flow.start_new_page(size=oriented(self.page_size, self.layout))
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
    self.flow.model,
    options=@pdf.RenderOptions::new(
      fonts=self.catalog.registry,
      truncate_widths=true,
    ),
  )
}
