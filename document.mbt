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
  /// the bounding boxes inside the margin box, innermost last
  priv boxes : Array[Box]
  /// each page's stack of graphics states (`graphics.mbt`; pdf-core's
  /// `GraphicStateStack`): a new page starts with a copy of the state of
  /// the page it was made from
  priv stacks : Array[Array[GraphicState]]
  /// each page's transformation, set up by the blocks around the current
  /// op (`transform.mbt`), in pagelayout's page space; a new page starts
  /// without one
  priv ctms : Array[@pagelayout.Matrix]
  /// the pages the open transformation blocks started on, kept current as
  /// pages are inserted before them
  priv open_pages : Array[Ref[Int]]
  /// each page's path being built (Prawn writes it into that page's
  /// content, to be painted there)
  priv paths : Array[Array[@pagelayout.PathSegment]]
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
  let doc = {
    flow,
    catalog,
    family: "Helvetica",
    size: 12.0,
    page_size: size,
    layout,
    boxes: [],
    stacks: [],
    ctms: [],
    open_pages: [],
    paths: [],
  }
  // a new page starts with the graphics state of the page it was made from,
  // as it is then (a page made by a page break included)
  flow.page_started = (from, to) => {
    let state = if from >= 0 && from < doc.stacks.length() {
      match doc.stacks[from].last() {
        Some(s) => s.copy()
        None => GraphicState::new()
      }
    } else {
      GraphicState::new()
    }
    doc.stacks.insert(to, [state])
    doc.ctms.insert(to, @pagelayout.identity)
    for page in doc.open_pages {
      if page.val >= to {
        page.val += 1
      }
    }
    doc.paths.insert(to, [])
  }
  // out of room: Prawn's rules for the bounds (`bounds.mbt`)
  flow.move_past_bottom = Some(() => doc.move_past_bottom())
  flow.start_new_page(size=(w, h))
  doc
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
) -> Unit raise PrawnError {
  // nothing to set: Prawn moves by the leading alone (an empty box has no
  // line gap)
  if string.is_empty() {
    self.move_down(leading)
    return
  }
  let style = self.style(size?)
  self.check(string, style, Some(self.flow.width()))
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
  self.track()
}

///|
/// Prawn's `move_down`.
pub fn Document::move_down(self : Document, amount : Double) -> Unit {
  self.flow.move_down(amount)
  self.track()
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
  self.reframe()
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
  let face = self.flow.font(style)
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
  self.check(string, style, Some(width.unwrap_or(self.flow.width())))
  self.flow.height_of(
    [{ text: string, style, anchor: None, }],
    {
      leading,
      padding_top: 0.0,
      padding_bottom: self.flow.font(style).line_gap_pt(style.size) + leading,
    },
    style,
    width?,
  )
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
  let face = self.flow.font(style)
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
  self.flow.go_to_page(number - 1)
  self.reframe()
}
