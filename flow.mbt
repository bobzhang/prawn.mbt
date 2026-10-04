///|
// A cursor-driven page flow in the manner of Prawn: content is inked top
// to bottom at a cursor, inside horizontal bounds that blocks indent and
// pad, and a new page starts when the cursor runs out. It emits the
// pagelayout page-model IR directly.
//
// Coordinates are pagelayout's: points, y down from the page top.

///|
/// Prawn's line metrics for a line height factor (asciidoctor-pdf's
/// `calc_line_metrics`).
pub(all) struct LineMetrics {
  leading : Double
  padding_top : Double
  padding_bottom : Double
}

///|
pub fn line_metrics(factor : Double, face : Face, size : Double) -> LineMetrics {
  let leading = factor * size - size
  let half = leading / 2.0
  { leading, padding_top: half + face.line_gap_pt(size), padding_bottom: half, }
}

///|
/// A point in the flow: page, cursor, and how many items the page held,
/// so backgrounds can be slid underneath content inked after it.
pub(all) struct Mark {
  page : Int
  y : Double
  item : Int
}

///|
/// A column box (Prawn's ColumnBox with `reflow_margins`): the bounds are
/// split into `count` columns `gap` apart; running out of room moves to
/// the next column at the box's top, and past the last one to a new page,
/// where the box starts at the page's top.
pub(all) struct Columns {
  count : Int
  /// the distance between the left edges of adjacent columns
  stride : Double
  mut current : Int
}

///|
pub(all) struct Flow {
  catalog : FontCatalog
  /// the page setup new pages take their size from, before any page
  setup : PageSetup
  /// what the document does at the fragment callbacks, and its font policy
  hooks : Hooks
  model : @pagelayout.PageModel
  /// a dry run (asciidoctor-pdf's scratch document): destinations and
  /// index pages are not recorded
  scratch : Bool
  /// the top of the page's content area
  page_top : Double
  /// the top of the current frame: `page_top`, or where a column box
  /// starts on its first page
  mut top : Double
  mut bottom : Double
  mut page : Int
  mut y : Double
  mut left : Double
  mut right : Double
  mut columns : Columns?
  /// the last line `typeset` placed: the line, its page and its baseline
  mut last_line : (Line, Int, Double)?
  /// whether that line was the first of its text (no hanging indent)
  mut last_line_first : Bool
  /// while above zero, what is inked does not count as content (Prawn's
  /// `tare_first_page_content_stream`: captions and backgrounds)
  mut taring : Int
  /// content was inked since the flow started, before its first page break
  mut inked : Bool
  /// at the flow's first page break: whether nothing had been inked
  /// (asciidoctor-pdf's `DetectEmptyFirstPage`); None before it
  mut first_break_empty : Bool?
  /// the left and right margins of a page by index, when they vary by page
  /// (`media=prepress`)
  mut page_margins : ((Int) -> (Double, Double))?
  /// the current page's left and right margins
  mut margin_left : Double
  mut margin_right : Double
  /// the size of the page the bounds were set for
  mut page_width_now : Double
  mut page_height_now : Double
  /// told of each new page (the page it was made from, the new page,
  /// inserted after it, so later pages move up by one),
  /// before it becomes current: what carries over from page to page
  /// (Prawn's graphics state) is copied then
  mut page_started : (Int, Int) -> Unit
  /// what to do when content runs out of room, instead of the next column
  /// or page below (a document that keeps bounds of its own sets it)
  mut move_past_bottom : (() -> Unit)?
  /// draws a run's underline and strikethrough instead (x, width,
  /// baseline, style, face): a document with Prawn's own decorations
  /// sets it
  mut decorate : ((Double, Double, Double, Style, Face) -> Array[
    @pagelayout.PageItem,
  ])?
}

///|
/// The page size and margins a document starts with (asciidoctor-pdf's
/// `build_pdf_options`: `page_size`, `page_layout`, `page_margin`), in
/// points.
pub(all) struct PageSetup {
  width : Double
  height : Double
  margin_top : Double
  margin_right : Double
  margin_bottom : Double
  margin_left : Double
}

///|
/// A flow over pages set up as `setup`, its text set from `catalog`, the
/// document answering `hooks`; `scratch` for a dry run.
pub fn Flow::new(
  catalog : FontCatalog,
  setup : PageSetup,
  hooks? : Hooks = Hooks::new(),
  scratch? : Bool = false,
) -> Flow {
  {
    catalog,
    setup,
    hooks,
    model: @pagelayout.PageModel::new(),
    scratch,
    page_top: setup.margin_top,
    top: setup.margin_top,
    bottom: setup.height - setup.margin_bottom,
    page: -1,
    y: setup.margin_top,
    left: setup.margin_left,
    right: setup.width - setup.margin_right,
    columns: None,
    last_line: None,
    last_line_first: false,
    taring: 0,
    inked: false,
    first_break_empty: None,
    page_margins: None,
    margin_left: setup.margin_left,
    margin_right: setup.margin_right,
    page_width_now: setup.width,
    page_height_now: setup.height,
    page_started: (_, _) => (),
    move_past_bottom: None,
    decorate: None,
  }
}

///|
/// Take the left and right margins of page `index` (`page_margins`; for
/// `media=prepress`, asciidoctor-pdf's `init_page` sets the recto or verso
/// margins), keeping any indentation from the margins.
fn Flow::apply_page_margins(self : Flow, index : Int) -> Unit {
  match self.page_margins {
    Some(margins_of) => {
      let (l, r) = margins_of(index)
      let width = self.model.pages[index].width_pt
      self.left = l + (self.left - self.margin_left)
      self.right = width - r - (width - self.margin_right - self.right)
      self.margin_left = l
      self.margin_right = r
    }
    None => ()
  }
}

///|
pub fn Flow::start_new_page(
  self : Flow,
  layout? : String,
  size? : (Double, Double),
) -> Unit {
  // a new page takes the current page's size and layout (Prawn's
  // `start_new_page`), or the size (as an imported page has) and the
  // layout asked for: landscape swaps the sides
  let (w, h) = match (size, self.model.pages.get(self.page)) {
    (Some(size), _) => size
    (None, Some(p)) => (p.width_pt, p.height_pt)
    (None, None) => (self.setup.width, self.setup.height)
  }
  let (w, h) = match layout {
    Some("landscape") if w < h => (h, w)
    Some("portrait") if w > h => (h, w)
    _ => (w, h)
  }
  // the new page comes right after the current one (Prawn inserts it
  // there; at the last page, that is the end)
  let index = self.page + 1
  self.model.pages.insert(index, { width_pt: w, height_pt: h, items: [], })
  (self.page_started)(self.page, index)
  self.page = index
  self.fit_page_size()
  self.apply_page_margins(self.page)
  self.top = self.page_top
  self.y = self.top
}

///|
/// The current page's height (the PDF's y axis is measured up from its
/// bottom).
pub fn Flow::page_h(self : Flow) -> Double {
  match self.model.pages.get(self.page) {
    Some(p) => p.height_pt
    None => self.setup.height
  }
}

///|
/// Fit the bounds to the current page's size: its bottom margin and right
/// margin stay where the page setup puts them.
fn Flow::fit_page_size(self : Flow) -> Unit {
  guard self.model.pages.get(self.page) is Some(p) else { return }
  // only a change of size moves the bounds (a flow may have bounds of its
  // own, as a table cell's or a dry run's)
  if p.height_pt != self.page_height_now {
    self.bottom += p.height_pt - self.page_height_now
    self.page_height_now = p.height_pt
  }
  if p.width_pt != self.page_width_now {
    self.right += p.width_pt - self.page_width_now
    self.page_width_now = p.width_pt
  }
}

///|
/// Move to the next page, creating it unless an earlier pass already did
/// (a block's background revisits pages its content spilled onto); in a
/// column box, to the next column first (Prawn's `move_past_bottom`).
pub fn Flow::advance_page(self : Flow) -> Unit {
  match self.move_past_bottom {
    Some(move_on) => {
      move_on()
      return
    }
    None => ()
  }
  match self.columns {
    Some(columns) if columns.current < columns.count - 1 => {
      columns.current += 1
      self.left += columns.stride
      self.right += columns.stride
      self.y = self.top
      return
    }
    Some(columns) => {
      let back = columns.stride * columns.current.to_double()
      self.left -= back
      self.right -= back
      columns.current = 0
    }
    None => ()
  }
  if self.first_break_empty is None {
    self.first_break_empty = Some(!self.inked)
  }
  if self.page + 1 < self.model.pages.length() {
    self.go_to_page(self.page + 1)
    self.top = self.page_top
    self.y = self.top
  } else {
    self.start_new_page()
  }
}

///|
/// Whether the current page is a verso page (an even page number).
pub fn Flow::on_verso(self : Flow) -> Bool {
  (self.page + 1) % 2 == 0
}

///|
/// Make page `index` the current page (Prawn's `go_to_page`), in its
/// margins; the cursor is left where it is.
pub fn Flow::go_to_page(self : Flow, index : Int) -> Unit {
  self.page = index
  self.fit_page_size()
  self.apply_page_margins(index)
}

///|
/// In a column box, move to its last column (Prawn's
/// `bounds.current_column = bounds.last_column`), so the next page break
/// starts a new page.
pub fn Flow::to_last_column(self : Flow) -> Unit {
  match self.columns {
    Some(columns) => {
      let shift = columns.stride *
        (columns.count - 1 - columns.current).to_double()
      self.left += shift
      self.right += shift
      columns.current = columns.count - 1
    }
    None => ()
  }
}

///|
/// Lay out `body` in `count` columns `gap` apart, starting at the cursor
/// (Prawn's `column_box` with `reflow_margins: true`); the cursor ends
/// where the first column did, or, when the box went on past it, at the
/// bottom of the last one.
pub fn Flow::column_box(
  self : Flow,
  count : Int,
  gap : Double,
  body : () -> Unit,
) -> Unit {
  let width = self.width()
  let bare = (width - gap * (count - 1).to_double()) / count.to_double()
  let saved = (self.left, self.right, self.top, self.columns)
  let columns : Columns = { count, stride: bare + gap, current: 0, }
  self.columns = Some(columns)
  self.top = self.y
  self.right = self.left + bare
  let start_page = self.page
  body()
  let current = columns.current
  self.columns = saved.3
  self.left = saved.0
  self.right = saved.1
  self.top = if self.page == start_page { saved.2 } else { self.page_top }
  if current > 0 {
    // the box stretched to the bottom of the columns before the last
    self.y = self.bottom
  }
}

///|
pub fn Flow::items(self : Flow) -> Array[@pagelayout.PageItem] {
  self.model.pages[self.page].items
}

///|
pub fn Flow::push(self : Flow, item : @pagelayout.PageItem) -> Unit {
  if !(item is Anchor(_)) {
    self.mark_inked()
  }
  self.items().push(item)
}

///|
/// Content goes on the page (see `inked`).
fn Flow::mark_inked(self : Flow) -> Unit {
  if self.taring == 0 {
    self.inked = true
  }
}

///|
/// Ink `body` as tared content: captions and backgrounds, which do not
/// keep a block on a page by themselves.
pub fn Flow::tared(self : Flow, body : () -> Unit) -> Unit {
  self.taring += 1
  body()
  self.taring -= 1
}

///|
/// Space left above the bottom margin (Prawn's `cursor`).
pub fn Flow::cursor(self : Flow) -> Double {
  self.bottom - self.y
}

///|
pub fn Flow::at_page_top(self : Flow) -> Bool {
  (self.y - self.top).abs() < 0.0001
}

///|
pub fn Flow::width(self : Flow) -> Double {
  self.right - self.left
}

///|
pub fn Flow::move_down(self : Flow, amount : Double) -> Unit {
  self.y += amount
}

///|
/// asciidoctor-pdf's `margin`: nothing at the top of a page, a move down
/// when it fits, else a new page.
pub fn Flow::margin(self : Flow, amount : Double) -> Unit {
  if amount == 0.0 || self.at_page_top() {
    return
  }
  if self.cursor() > amount {
    self.move_down(amount)
  } else {
    self.advance_page()
  }
}

///|
/// The bottom padding of a padded box: a move down when it fits, else the
/// next page (Prawn's `move_past_bottom`).
pub fn Flow::pad_bottom(self : Flow, amount : Double) -> Unit {
  if self.at_page_top() {
    return
  }
  if self.cursor() > amount {
    self.move_down(amount)
  } else {
    self.advance_page()
  }
}

///|
pub fn[T] Flow::indent(
  self : Flow,
  left : Double,
  right : Double,
  body : () -> T,
) -> T {
  self.left += left
  self.right -= right
  let result = body()
  self.left -= left
  self.right += right
  result
}

///|
pub fn Flow::mark(self : Flow) -> Mark {
  { page: self.page, y: self.y, item: self.items().length(), }
}

///|
pub fn Flow::font(self : Flow, style : Style) -> Face {
  let (bold, italic) = style.face_style()
  self.text().face(style.family, bold, italic)
}

///|
/// Prawn's `width_of` a plain string in `style`'s font, trailing spaces
/// included (asciidoctor-pdf's `rendered_width_of_string`): the truncated
/// glyph widths, kerned.
pub fn Flow::width_of(self : Flow, text : String, style : Style) -> Double {
  let face = self.font(style)
  let mut width = 0.0
  let n = text.length()
  for i in 0..<n {
    let cp = text[i].to_int()
    width += face.prawn_width(cp)
    if i + 1 < n {
      width += face.kerning(cp, text[i + 1].to_int())
    }
  }
  width * style.size / 1000.0
}

///|
pub fn Flow::add_anchor(
  self : Flow,
  name : String,
  x : Double,
  y : Double,
) -> Unit {
  self.push(Anchor({ name: pdf_anchor_name(name), x_pt: x, y_pt: y, }))
}

///|
pub fn rect_item(
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  fill? : Color,
  stroke? : Color,
  stroke_width? : Double = 0.0,
) -> @pagelayout.PageItem {
  Rect({
    x_pt: x,
    y_pt: y,
    w_pt: w,
    h_pt: h,
    fill,
    stroke,
    stroke_w_pt: stroke_width,
  })
}

///|
/// A horizontal rule `width` thick centred on `y`.
pub fn hrule(
  x1 : Double,
  x2 : Double,
  y : Double,
  width : Double,
  color : Color,
) -> @pagelayout.PageItem {
  rect_item(x1, y - width / 2.0, x2 - x1, width, fill=color)
}

///|
/// A dashed horizontal rule (dashes and gaps four times its width, as
/// Prawn's `dash` in asciidoctor-pdf's dashed style), as filled segments.
pub fn dashed_hrule(
  x1 : Double,
  x2 : Double,
  y : Double,
  width : Double,
  color : Color,
) -> Array[@pagelayout.PageItem] {
  let dash = width * 4.0
  let items = []
  let mut x = x1
  while x < x2 {
    items.push(hrule(x, @cmp.minimum(x + dash, x2), y, width, color))
    x += dash * 2.0
  }
  items
}

///|
/// A vertical rule `width` thick centred on `x`.
pub fn vrule(
  x : Double,
  y1 : Double,
  y2 : Double,
  width : Double,
  color : Color,
) -> @pagelayout.PageItem {
  rect_item(x - width / 2.0, y1, width, y2 - y1, fill=color)
}

///|
/// The items that draw one placed line with its left edge at `x0` and its
/// baseline at `baseline`: backgrounds, glyph runs, decorations, link
/// regions and anchors.
pub fn Flow::line_items(
  self : Flow,
  line : Line,
  x0 : Double,
  baseline : Double,
) -> Array[@pagelayout.PageItem] {
  let items : Array[@pagelayout.PageItem] = []
  // the marks of highlighted source lines: behind everything else of the
  // line, its images and glyphs (Ruby paints them as the line starts)
  for mark in line.marks {
    let (x, style, face) = mark
    match (style.background, style.code_background) {
      (Some(color), Some(extent)) =>
        items.push(
          self.code_background_item(
            extent,
            x0 + x,
            0.0,
            baseline,
            face,
            style.size,
            color,
          ),
        )
      _ => ()
    }
  }
  // inline images (InlineImageRenderer): one taller than one and a half
  // lines sits on the text's descender, a smaller one is centred on its
  // placeholder's box
  for placed in line.images {
    let (x, index, w, h, increased, style, face) = placed
    let a = face.ascender_pt(style.size)
    let d = face.descender_pt(style.size)
    let (top, box_top, box_height) = if increased {
      (baseline + d - h, baseline + d - h, h)
    } else {
      (baseline - a + (a + d - h) / 2.0, baseline - a, a + d)
    }
    items.append((self.hooks.image_items)(self, index, x0 + x, top, w, h))
    match style.link {
      Some(target) =>
        items.push(
          Link({
            x_pt: x0 + x,
            y_pt: box_top,
            w_pt: w,
            h_pt: box_height,
            target,
          }),
        )
      None => ()
    }
  }
  for link in line.empty_links {
    let (x, style, face) = link
    guard style.link is Some(target) else { continue }
    let a = face.ascender_pt(style.size)
    items.push(
      Link({
        x_pt: x0 + x,
        y_pt: baseline - a,
        w_pt: 0.0,
        h_pt: a + face.descender_pt(style.size),
        target,
      }),
    )
  }
  for anchor in line.anchors {
    items.push(
      Anchor({
        name: pdf_anchor_name(anchor.0),
        x_pt: x0 + anchor.1,
        y_pt: baseline - line.ascender,
      }),
    )
  }
  for run in line.runs {
    let style = run.style
    // the fragment's callback (Prawn's fragment `callback`), when inked
    // for good
    if style.callback >= 0 && !self.scratch {
      (self.hooks.fragment_inked)(style.callback)
    }
    let x = x0 + run.x
    let a = run.face.ascender_pt(style.size)
    let d = run.face.descender_pt(style.size)
    let rise = match style.script {
      1 => 0.85 * a
      -1 => -d
      _ => 0.0
    }
    match style.background {
      Some(color) =>
        items.push(
          match style.code_background {
            Some(extent) =>
              self.code_background_item(
                extent,
                x,
                run.width,
                baseline,
                run.face,
                style.size,
                color,
              )
            None => {
              let o = style.border_offset
              rect_item(
                x - o,
                baseline - rise - a - o,
                run.width + 2.0 * o,
                a + d + 2.0 * o,
                fill=color,
              )
            }
          },
        )
      None => ()
    }
    let (bold, italic) = style.face_style()
    let font = self.model.add_font({ family: style.family, bold, italic, })
    items.push(
      Text({
        font,
        size_pt: style.size,
        x_pt: x,
        baseline_pt: baseline - rise,
        text: run.text,
        advances_pt: run.advances,
        color: style.color,
      }),
    )
    match self.decorate {
      Some(decorate) if style.underline || style.strike =>
        items.append(decorate(x, run.width, baseline, style, run.face))
      _ => ()
    }
    let thickness = style.size / 18.0
    if style.underline && self.decorate is None {
      items.push(
        hrule(
          x,
          x + run.width,
          baseline + style.size * 0.1,
          thickness,
          style.color,
        ),
      )
    }
    if style.strike && self.decorate is None {
      items.push(
        hrule(
          x,
          x + run.width,
          baseline - style.size * 0.3,
          thickness,
          style.color,
        ),
      )
    }
    match style.link {
      Some(target) =>
        items.push(
          Link({
            x_pt: x,
            y_pt: baseline - rise - a,
            w_pt: run.width,
            h_pt: a + d,
            target,
          }),
        )
      None => ()
    }
  }
  items
}

///|
/// Draw one placed line on the current page.
pub fn Flow::ink_line(
  self : Flow,
  line : Line,
  x0 : Double,
  baseline : Double,
) -> Unit {
  if !line.runs.is_empty() || !line.images.is_empty() {
    self.mark_inked()
  }
  self.items().append(self.line_items(line, x0, baseline))
  if !self.scratch {
    // the document learns each anchor's page (InlineDestinationMarker)
    for anchor in line.anchors {
      (self.hooks.anchor_inked)(anchor.0, self.page + 1)
    }
  }
}

///|
/// The ascender, descender and height a placed line takes: its fragments'
/// largest, or the document font's for an empty line. With
/// `normalize_line_height`, the document font's count on every line, as
/// asciidoctor-pdf's arranger puts a zero-width space in that font at the
/// start of each line (so a line of code in a list takes the prose line's
/// height, not the smaller one of the monospace font).
pub fn line_extent(
  line : Line,
  base_face : Face,
  size : Double,
  normalize_line_height : Bool,
) -> (Double, Double, Double) {
  let a = base_face.ascender_pt(size)
  let d = base_face.descender_pt(size)
  let h = base_face.height_pt(size)
  if line.height == 0.0 {
    (a, d, h)
  } else if normalize_line_height {
    (
      @cmp.maximum(a, line.ascender),
      @cmp.maximum(d, line.descender),
      @cmp.maximum(h, line.height),
    )
  } else {
    (line.ascender, line.descender, line.height)
  }
}

///|
/// Ink formatted text at the cursor, flowing onto new pages as needed —
/// asciidoctor-pdf's `typeset_text` over Prawn's `text`.
pub fn Flow::typeset(
  self : Flow,
  fragments : Array[Fragment],
  metrics : LineMetrics,
  base : Style,
  align? : Alignment = Left,
  bottom_gutter? : Double = 0.0,
  hanging_indent? : Double = 0.0,
  normalize_line_height? : Bool = false,
  first_line_style? : Style,
  text_indent? : Double = 0.0,
) -> Unit {
  self.last_line = None
  // a hanging indent: the first line takes the whole width, the next ones
  // are indented (Prawn's `indent_paragraphs` negated inside an indent);
  // a text indent (`indent_paragraphs`): the first line of each paragraph
  // (the text, and each line after a hard break) is indented;
  // a first line in a style of its own is broken off first
  let mut paragraph_starts : Array[Bool] = []
  let lines = match first_line_style {
    Some(first) => {
      // the first line box is indented (Prawn's `indent_paragraphs` in
      // `text_with_formatted_first_line`); the rest is not
      let (line, rest) = split_first_line(
        restyle_fragments(fragments, first),
        fragments,
        self.text(),
        self.width() - text_indent,
        align,
      )
      if text_indent > 0.0 {
        paragraph_starts = [true]
      }
      if rest.is_empty() {
        [line]
      } else {
        [line, ..typeset_lines(rest, self.text(), self.width(), align)]
      }
    }
    None if text_indent > 0.0 => {
      let (lines, starts) = typeset_paragraph_lines(
        fragments,
        self.text(),
        self.width(),
        align,
        first_width=self.width() - text_indent,
        indent_paragraphs=true,
      )
      paragraph_starts = starts
      lines
    }
    None =>
      typeset_lines(
        fragments,
        self.text(),
        self.width() - hanging_indent,
        align,
        first_width=self.width(),
      )
  }
  let base_face = self.font(base)
  let mut index = 0
  while index < lines.length() {
    // Prawn's text box: the first line hangs from the top by its ascender,
    // each next one drops by its line height plus the leading
    // a line taller than a fresh page is inked anyway rather than looping
    let fresh = self.at_page_top()
    self.y += metrics.padding_top
    let box_top = self.y
    let available = self.cursor()
    let mut baseline = 0.0
    let mut depth = 0.0
    let mut placed = 0
    while index < lines.length() {
      let line = lines[index]
      let (a, d, h) = line_extent(
        line,
        base_face,
        base.size,
        normalize_line_height,
      )
      let next = if placed == 0 { a } else { baseline + h + metrics.leading }
      // the last line keeps clear of the padding below it (asciidoctor-pdf's
      // bottom gutter)
      let gutter = if index == lines.length() - 1 { bottom_gutter } else { 0.0 }
      if next + d + gutter > available + 0.0001 && !(fresh && placed == 0) {
        break
      }
      baseline = next
      depth = d
      let x = if paragraph_starts.get(index) is Some(true) {
        self.left + text_indent
      } else if index == 0 {
        self.left
      } else {
        self.left + hanging_indent
      }
      self.ink_line(line, x, box_top + baseline)
      self.last_line = Some((line, self.page, box_top + baseline))
      self.last_line_first = index == 0
      placed += 1
      index += 1
    }
    if placed > 0 {
      self.y = box_top + baseline + depth
    }
    if index < lines.length() {
      self.advance_page()
    }
  }
  self.y += metrics.padding_bottom
}

///|
/// The height `typeset` would take for `fragments` in the current bounds
/// (asciidoctor-pdf's `height_of_typeset_text`), ignoring page breaks.
pub fn Flow::height_of(
  self : Flow,
  fragments : Array[Fragment],
  metrics : LineMetrics,
  base : Style,
  normalize_line_height? : Bool = false,
  width? : Double,
) -> Double {
  let lines = typeset_lines(
    fragments,
    self.text(),
    width.unwrap_or(self.width()),
    Left,
  )
  let base_face = self.font(base)
  let mut baseline = 0.0
  let mut depth = 0.0
  for index, line in lines {
    let (a, d, h) = line_extent(
      line,
      base_face,
      base.size,
      normalize_line_height,
    )
    baseline = if index == 0 { a } else { baseline + h + metrics.leading }
    depth = d
  }
  metrics.padding_top + baseline + depth + metrics.padding_bottom
}

///|
/// Slide `make(page, top, bottom, first, last)` underneath everything inked
/// since `start`, on every page from `start` to the cursor: the painter's
/// order of a background drawn before its content, without a dry run.
pub fn Flow::underlay(
  self : Flow,
  start : Mark,
  make : (Double, Double, Bool, Bool) -> Array[@pagelayout.PageItem],
) -> Unit {
  let end_page = self.page
  let end_y = self.y
  for page in start.page..<=end_page {
    let first = page == start.page
    let last = page == end_page
    let top = if first { start.y } else { self.page_top }
    let bottom = if last { end_y } else { self.bottom }
    if bottom - top <= 0.0 {
      continue
    }
    let items = self.model.pages[page].items
    let at = if first { start.item } else { 0 }
    for offset, item in make(top, bottom, first, last) {
      items.insert(at + offset, item)
    }
  }
}

///|
/// What the flow sets text with.
pub fn Flow::text(self : Flow) -> TextContext {
  { catalog: self.catalog, hooks: self.hooks, }
}

///|
/// Whether `height` fits below the cursor (prawn-table's `fits_on_page?`).
pub fn Flow::fits(self : Flow, height : Double, y? : Double = self.y) -> Bool {
  height < self.bottom - y + 1.0e-9
}

///|
/// A named destination for the block at the cursor (asciidoctor-pdf's
/// `add_dest_for_block`).
pub fn Flow::dest_x(self : Flow) -> Double {
  // `add_dest_for_block`: `bounds.absolute_left.truncate 4`, 0 when at the
  // margin
  let left = (self.left * 10000.0).floor() / 10000.0
  if left <= self.margin_left {
    0.0
  } else {
    left
  }
}

///|
/// Prawn's formatted text box with a height (`text_box`): the lines of
/// `fragments` set `width` wide from `x` (the first one `text_indent`
/// further in, Prawn's `indent_paragraphs`), the first hanging from the
/// cursor plus the line padding, as many as fit in `height`. Returns the
/// fragments that did not fit and the baseline of the last line inked
/// (None when none was); the cursor does not move.
pub fn Flow::typeset_box(
  self : Flow,
  fragments : Array[Fragment],
  metrics : LineMetrics,
  base : Style,
  align~ : Alignment,
  x~ : Double,
  width~ : Double,
  height~ : Double,
  text_indent~ : Double,
) -> (Array[Fragment], Double?) {
  self.last_line = None
  let base_face = self.font(base)
  let top = self.y + metrics.padding_top
  let mut remaining = self.text().apply_fallbacks(fragments)
  let mut baseline = 0.0
  let mut placed = 0
  let mut last : Double? = None
  while !remaining.is_empty() {
    let indent = if placed == 0 { text_indent } else { 0.0 }
    let (line, rest) = split_first_line(
      remaining,
      remaining,
      self.text(),
      width - indent,
      align,
    )
    let (a, d, h) = line_extent(line, base_face, base.size, false)
    let next = if placed == 0 { a } else { baseline + h + metrics.leading }
    if next + d > height + 0.0001 {
      break
    }
    baseline = next
    self.ink_line(line, x + indent, top + baseline)
    self.last_line = Some((line, self.page, top + baseline))
    self.last_line_first = placed == 0
    last = Some(top + baseline)
    placed += 1
    remaining = rest
  }
  (remaining, last)
}
