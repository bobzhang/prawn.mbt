///|
// Prawn's bounding boxes, modelled as Prawn keeps them: one current box
// (`@bounding_box`), each box with its parent, and a margin box per page
// (`generate_margin_box`). A block opening a box restores the box it saved
// when it ends, whatever happened in between. Coordinates here are Prawn's
// (points, y up from the bottom of the page).

///|
/// A bounding box: its top left corner on the page, its width, and its
/// height, or none for a stretchy box that grows with its content.
priv struct Box {
  /// with the left padding (`indent`) in it, as Prawn's `@x`
  mut left : Double
  /// a column box's moves to its parent's top on a new page when it
  /// reflows its margins
  mut top : Double
  /// with the padding taken off (a column box's is not: its columns are
  /// narrowed instead)
  mut width : Double
  height : Double?
  /// how far a stretchy box has grown
  mut stretched : Double
  /// the box it was opened in; none for a margin box
  parent : Box?
  /// a column box's columns
  columns : ColumnState?
  /// the indentation added (`total_left_padding`, `total_right_padding`)
  mut total_left : Double
  mut total_right : Double
}

///|
/// A column box's columns (Prawn's `ColumnBox`).
priv struct ColumnState {
  count : Int
  spacer : Double
  mut current : Int
  reflow_margins : Bool
}

///|
/// Where a box's content goes across: its left side on the page and its
/// width (a column box's current column, `(width - spacer * (n - 1)) / n`
/// wide less its padding).
fn Box::side(self : Box) -> (Double, Double) {
  match self.columns {
    None => (self.left, self.width)
    Some(c) => {
      let bare = (self.width - c.spacer * (c.count - 1).to_double()) /
        c.count.to_double()
      (
        self.left + (bare + c.spacer) * c.current.to_double(),
        bare - (self.total_left + self.total_right),
      )
    }
  }
}

///|
/// A box's height: a stretchy box's grows to the document's position.
fn Box::height_at(self : Box, y : Double) -> Double {
  match self.height {
    Some(h) => h
    None => {
      if self.top - y > self.stretched {
        self.stretched = self.top - y
      }
      self.stretched
    }
  }
}

///|
fn Box::bottom_at(self : Box, y : Double) -> Double {
  self.top - self.height_at(y)
}

///|
/// Prawn's `add_left_padding` and `add_right_padding` (negative amounts
/// subtract): a box moves its left side in and narrows; a column box
/// moves and narrows its columns, keeping its width.
fn Box::pad(self : Box, left : Double, right : Double) -> Unit {
  self.total_left += left
  self.total_right += right
  self.left += left
  if self.columns is None {
    self.width -= left + right
  }
}

///|
/// The bounds content is set in, as Prawn's `bounds` reports them.
pub(all) struct Bounds {
  /// relative to the box itself: 0, or a column box's column's offset
  left : Double
  bottom : Double
  width : Double
  height : Double
  /// on the page
  absolute_left : Double
  absolute_top : Double
}

///|
/// The document's position (Prawn's `y`): up from the page bottom.
fn Document::y(self : Document) -> Double {
  self.flow.page_h() - self.flow.y
}

///|
fn Document::set_y(self : Document, y : Double) -> Unit {
  self.flow.y = self.flow.page_h() - y
  self.track()
}

///|
/// Prawn's `y=` updates the current box's height (`update_height`): a
/// stretchy box keeps the depth its content reached, even when the
/// position moves back up (`float`). Called after every move.
fn Document::track(self : Document) -> Unit {
  if self.bbox.height is None {
    self.bbox.height_at(self.y()) |> ignore
  }
}

///|
/// The current box: a bounding box, or a margin box.
fn Document::current_box(self : Document) -> Box {
  self.bbox
}

///|
/// The margin box of the current page (Prawn's `generate_margin_box`): the
/// page's size less its margins, with the indentation the last margin box
/// had; it becomes the current box unless a box with a parent is.
fn Document::generate_margin_box(self : Document) -> Unit {
  let flow = self.flow
  let page_h = flow.page_h()
  let page_w = flow.model.pages[flow.page].width_pt
  let margin : Box = {
    left: flow.margin_left,
    top: page_h - flow.setup.margin_top,
    width: page_w - flow.margin_left - flow.margin_right,
    height: Some(page_h - flow.setup.margin_top - flow.setup.margin_bottom),
    stretched: 0.0,
    parent: None,
    columns: None,
    total_left: 0.0,
    total_right: 0.0,
  }
  margin.pad(self.margin.total_left, self.margin.total_right)
  self.margin = margin
  if self.bbox.parent is None {
    self.bbox = margin
  }
}

///|
/// After a change of page: the page's margin box, the current box set in
/// Flow, and the position at its top (`size_changed`: a new page of
/// another size or layout makes the margin box current, as Prawn does).
fn Document::page_changed(
  self : Document,
  size_changed? : Bool = false,
) -> Unit {
  self.generate_margin_box()
  if size_changed {
    self.bbox = self.margin
  }
  self.frame(self.bbox)
  self.set_y(self.bbox.top)
}

///|
/// Prawn's `bounds`.
pub fn Document::bounds(self : Document) -> Bounds {
  let box = self.bbox
  // a column box: the current column, `left` its offset in the box
  let (side, width) = box.side()
  {
    left: side - box.left,
    bottom: 0.0,
    width,
    height: box.height_at(self.y()),
    absolute_left: box.left,
    absolute_top: box.top,
  }
}

///|
/// Sets Flow's frame to `box`: its side (a column box's current column),
/// its top, and the bottom text runs to (a box's own, or for a stretchy
/// box the margin box's).
fn Document::frame(self : Document, box : Box) -> Unit {
  let flow = self.flow
  let page_h = flow.page_h()
  let (side, width) = box.side()
  flow.left = side
  flow.right = side + width
  flow.top = page_h - box.top
  let bottom = match box.height {
    Some(h) => box.top - h
    None => self.margin.bottom_at(self.y())
  }
  flow.bottom = page_h - bottom
}

///|
/// Opens `box` in the current box: `body`, then the box saved before is
/// current again (Prawn's `init_bounding_box`, `init_column_box`).
fn Document::open_box(
  self : Document,
  box : Box,
  body : () -> Unit raise,
  after : () -> Unit,
) -> Unit raise {
  let parent = self.bbox
  self.bbox = box
  self.frame(box)
  self.set_y(box.top)
  defer {
    self.bbox = parent
    self.frame(parent)
  }
  body()
  after()
}

///|
/// Prawn's `bounding_box`: `body` set in a box whose top left corner is
/// `at` (relative to the bottom left of the current bounds), `width` wide
/// and `height` tall, or stretchy. Afterwards the position is below the
/// current box (when it has a height), or where it was when nothing was
/// set.
pub fn Document::bounding_box(
  self : Document,
  at : (Double, Double),
  width : Double,
  height? : Double,
  body : () -> Unit raise,
) -> Unit raise {
  let parent = self.bbox
  let original_y = self.y()
  let box : Box = {
    left: parent.left + at.0,
    top: parent.bottom_at(original_y) + at.1,
    width,
    height,
    stretched: 0.0,
    parent: Some(parent),
    columns: None,
    total_left: 0.0,
    total_right: 0.0,
  }
  self.open_box(box, body, () => {
    // the box current now: a new page of another size may have made it
    // the margin box
    let current = self.bbox
    if self.y() == current.top {
      self.set_y(original_y)
    }
    if current.height is Some(_) {
      self.set_y(current.bottom_at(self.y()))
    }
  })
}

///|
/// Prawn's `column_box`: `body` set in `columns` columns `spacer` apart (by
/// default the font size) in a box at `at`, `width` wide and `height` tall
/// or stretchy; content runs down a column, then to the next, then to a
/// new page. Afterwards the position is at the current box's bottom.
pub fn Document::column_box(
  self : Document,
  at : (Double, Double),
  width : Double,
  height? : Double,
  columns? : Int = 3,
  spacer? : Double,
  reflow_margins? : Bool = false,
  body : () -> Unit raise,
) -> Unit raise {
  let parent = self.bbox
  let box : Box = {
    left: parent.left + at.0,
    top: parent.bottom_at(self.y()) + at.1,
    width,
    height,
    stretched: 0.0,
    parent: Some(parent),
    columns: Some({
      count: columns,
      spacer: spacer.unwrap_or(self.size),
      current: 0,
      reflow_margins,
    }),
    total_left: 0.0,
    total_right: 0.0,
  }
  self.open_box(box, body, () => self.set_y(self.bbox.bottom_at(self.y())))
}

///|
/// Prawn's `indent`: `body` set with the current bounds narrowed by `left`
/// and `right`; afterwards the padding comes off the bounds current then.
pub fn Document::indent(
  self : Document,
  left : Double,
  right? : Double = 0.0,
  body : () -> Unit raise,
) -> Unit raise {
  self.bbox.pad(left, right)
  self.frame(self.bbox)
  defer {
    self.bbox.pad(-left, -right)
    self.frame(self.bbox)
  }
  body()
}

///|
/// Prawn's `float`: `body`, then back to the page and position it started
/// at.
pub fn Document::float(self : Document, body : () -> Unit raise) -> Unit raise {
  let page = self.flow.page
  let y = self.y()
  defer {
    if self.flow.page != page {
      self.flow.go_to_page(page)
      self.page_changed()
    }
    self.set_y(y)
  }
  body()
}

///|
/// Prawn's `move_past_bottom`, when content runs out of room: a column
/// box moves to its next column, past the last one to a new page (with
/// `reflow_margins`, at the top of its parent); any other box to the next
/// page, made if there is none.
fn Document::move_past_bottom(self : Document) -> Unit {
  // a text being set carries on in a fresh box on the next column or
  // page: the document's position starts again at its top
  defer (if self.text_y is Some(_) {
    self.text_y = Some(self.flow.y)
    self.text_start = self.flow.y
  })
  // a stretchy box keeps the depth reached before the position moves on,
  // below the line gap Prawn's `text` moves down by first
  self.flow.y += self.pending_gap
  self.track()
  let box = self.bbox
  match box.columns {
    Some(c) => {
      c.current = (c.current + 1) % c.count
      if c.current != 0 {
        self.frame(box)
        self.set_y(box.top)
        return
      }
      if c.reflow_margins {
        match box.parent {
          Some(parent) => box.top = parent.top
          None => ()
        }
      }
      self.new_page()
    }
    None =>
      if self.flow.page + 1 < self.flow.model.pages.length() {
        self.flow.go_to_page(self.flow.page + 1)
        self.page_changed()
      } else {
        self.new_page()
      }
  }
}
