///|
// Prawn's bounding boxes: the bounds content is set in. Coordinates here are
// Prawn's (points, y up from the bottom of the page).

///|
/// A bounding box: its top left corner on the page, its width, and its
/// height, or none for a stretchy box that grows with its content.
priv struct Box {
  mut left : Double
  /// a column box's moves to its parent's top on a new page when it
  /// reflows its margins
  mut top : Double
  mut width : Double
  height : Double?
  /// how far a stretchy box has grown
  mut stretched : Double
  /// the margin box's bottom (Flow's coordinates): where text in a
  /// stretchy box runs to
  margin_bottom : Double
  /// a column box's columns
  columns : ColumnState?
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
/// wide).
fn Box::side(self : Box) -> (Double, Double) {
  match self.columns {
    None => (self.left, self.width)
    Some(c) => {
      let bare = (self.width - c.spacer * (c.count - 1).to_double()) /
        c.count.to_double()
      (self.left + (bare + c.spacer) * c.current.to_double(), bare)
    }
  }
}

///|
/// The bounds content is set in, as Prawn's `bounds` reports them.
pub(all) struct Bounds {
  /// relative to the box itself: always 0
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
/// Prawn's `y=` updates the innermost box's height (`update_height`): a
/// stretchy box keeps the depth its content reached, even when the
/// position moves back up (`float`). Called after every move.
fn Document::track(self : Document) -> Unit {
  match self.boxes.last() {
    Some(box) if box.height is None => box.height_at(self.y()) |> ignore
    _ => ()
  }
}

///|
/// The innermost box: a bounding box, or the page's margin box.
fn Document::current_box(self : Document) -> Box {
  match self.boxes.last() {
    Some(box) => box
    None => {
      let page_h = self.flow.page_h()
      {
        left: self.flow.left,
        top: page_h - self.flow.top,
        width: self.flow.right - self.flow.left,
        height: Some(self.flow.bottom - self.flow.top),
        stretched: 0.0,
        margin_bottom: self.flow.bottom,
        columns: None,
      }
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
/// Prawn's `bounds`.
pub fn Document::bounds(self : Document) -> Bounds {
  let box = self.current_box()
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
/// Prawn's `bounding_box`: `body` set in a box whose top left corner is
/// `at` (relative to the bottom left of the current bounds), `width` wide
/// and `height` tall, or stretchy. Afterwards the position is below a box
/// with a height, and where the content ended in a stretchy one.
pub fn Document::bounding_box(
  self : Document,
  at : (Double, Double),
  width : Double,
  height? : Double,
  body : () -> Unit raise,
) -> Unit raise {
  let parent = self.current_box()
  let original_y = self.y()
  let top = parent.top - parent.height_at(original_y) + at.1
  let box = {
    left: parent.left + at.0,
    top,
    width,
    height,
    stretched: 0.0,
    margin_bottom: parent.margin_bottom,
    columns: None,
  }
  let flow = self.flow
  let (left, right, frame_top, bottom) = (
    flow.left,
    flow.right,
    flow.top,
    flow.bottom,
  )
  self.boxes.push(box)
  self.frame(box)
  self.set_y(top)
  defer {
    self.boxes.pop() |> ignore
    flow.left = left
    flow.right = right
    flow.top = frame_top
    flow.bottom = bottom
  }
  body()
  // nothing set: the position is where it was
  if self.y() == top {
    self.set_y(original_y)
  }
  match height {
    Some(h) => self.set_y(top - h)
    None => ()
  }
}

///|
/// Prawn's `indent`: `body` set with the bounds narrowed by `left` and
/// `right`.
pub fn Document::indent(
  self : Document,
  left : Double,
  right? : Double = 0.0,
  body : () -> Unit raise,
) -> Unit raise {
  let box = self.boxes.last()
  match box {
    Some(b) => {
      b.left += left
      b.width -= left + right
    }
    None => ()
  }
  self.flow.left += left
  self.flow.right -= right
  defer {
    match box {
      Some(b) => {
        b.left -= left
        b.width += left + right
      }
      None => ()
    }
    self.flow.left -= left
    self.flow.right += right
  }
  body()
}

///|
/// Prawn's `float`: `body`, then back to the page and position it started
/// at.
pub fn Document::float(self : Document, body : () -> Unit raise) -> Unit raise {
  let page = self.flow.page
  let y = self.flow.y
  defer {
    if self.flow.page != page {
      self.flow.go_to_page(page)
    }
    self.flow.y = y
    self.track()
  }
  body()
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
  flow.bottom = match box.height {
    Some(h) => page_h - (box.top - h)
    None => box.margin_bottom
  }
}

///|
/// After a change of page: the innermost box carries over (Prawn keeps its
/// bounds), and the position is at its top.
fn Document::reframe(self : Document) -> Unit {
  match self.boxes.last() {
    Some(box) => {
      self.frame(box)
      self.set_y(box.top)
    }
    None => self.flow.y = self.flow.top
  }
}

///|
/// Prawn's `move_past_bottom`, when content runs out of room: a column
/// box moves to its next column, past the last one to a new page (with
/// `reflow_margins`, at the top of its parent); any other box to the next
/// page, made if there is none.
fn Document::move_past_bottom(self : Document) -> Unit {
  match self.boxes.last() {
    Some({ columns: Some(c), .. } as box) => {
      c.current = (c.current + 1) % c.count
      if c.current != 0 {
        self.frame(box)
        self.set_y(box.top)
        return
      }
      if c.reflow_margins {
        let parent = if self.boxes.length() >= 2 {
          self.boxes[self.boxes.length() - 2]
        } else {
          self.root_box()
        }
        box.top = parent.top
      }
      self.flow.start_new_page()
      self.reframe()
    }
    _ => {
      if self.flow.page + 1 < self.flow.model.pages.length() {
        self.flow.go_to_page(self.flow.page + 1)
      } else {
        self.flow.start_new_page()
      }
      self.reframe()
    }
  }
}

///|
/// The margin box of the current page, whatever boxes are open.
fn Document::root_box(self : Document) -> Box {
  let flow = self.flow
  let page_h = flow.page_h()
  let bottom = match self.boxes.get(0) {
    Some(b) => b.margin_bottom
    None => flow.bottom
  }
  {
    left: flow.margin_left,
    top: page_h - flow.page_top,
    width: flow.model.pages[flow.page].width_pt -
    flow.margin_left -
    flow.margin_right,
    height: Some(bottom - flow.page_top),
    stretched: 0.0,
    margin_bottom: bottom,
    columns: None,
  }
}

///|
/// Prawn's `column_box`: `body` set in `columns` columns `spacer` apart (by
/// default the font size) in a box at `at`, `width` wide and `height` tall
/// or stretchy; content runs down a column, then to the next, then to a
/// new page. Afterwards the position is at the box's bottom.
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
  let parent = self.current_box()
  let top = parent.top - parent.height_at(self.y()) + at.1
  let box = {
    left: parent.left + at.0,
    top,
    width,
    height,
    stretched: 0.0,
    margin_bottom: parent.margin_bottom,
    columns: Some({
      count: columns,
      spacer: spacer.unwrap_or(self.size),
      current: 0,
      reflow_margins,
    }),
  }
  let flow = self.flow
  let (left, right, frame_top, bottom) = (
    flow.left,
    flow.right,
    flow.top,
    flow.bottom,
  )
  self.boxes.push(box)
  self.frame(box)
  self.set_y(top)
  defer {
    self.boxes.pop() |> ignore
    flow.left = left
    flow.right = right
    flow.top = frame_top
    flow.bottom = bottom
  }
  body()
  self.set_y(box.top - box.height_at(self.y()))
}
