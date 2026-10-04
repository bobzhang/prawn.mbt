///|
// What the document keeps for each page, in one record (Prawn's
// `PDF::Core::Page` and what Prawn::Document keeps for it): the page's
// items, its graphics state stack, the transformation the blocks around
// the current op set up, the path being built, and its size and layout.
// Holding the record keeps hold of the page however pages are inserted
// before it.

///|
priv struct PageState {
  /// the page's items (pagelayout's page model): what is drawn on it
  items : Array[@pagelayout.PageItem]
  /// pdf-core's `GraphicStateStack` (`graphics.mbt`): a new page starts
  /// with a copy of the state of the page it was made from
  stack : Array[GraphicState]
  /// set up by the blocks around the current op (`transform.mbt`), in
  /// pagelayout's page space; a new page starts without one
  mut ctm : @pagelayout.Matrix
  /// the path being built (Prawn writes it into the page's content, to be
  /// painted there)
  path : Array[@pagelayout.PathSegment]
  /// the size as given and the layout (Prawn keeps them apart: a
  /// landscape page reverses the size, whatever its shape); a new page
  /// takes the current page's
  geometry : ((Double, Double), String)
  /// where the page's content saves and restores the graphics state
  /// (PDF's q, with what it sets up, and Q), by the position among its
  /// items: Prawn writes a block's q on the page it starts on and its Q on
  /// the page current when it ends, so a q may stay open (`render` closes
  /// what is open at the end of the page) and a Q may restore nothing
  marks : Array[(Int, ContentMark)]
  /// the transformations the page's open q's saved, innermost last
  saved_ctms : Array[@pagelayout.Matrix]
}

///|
/// A save or a restore in a page's content.
priv enum ContentMark {
  /// q (PDF's save), then what the block sets up (a transformation, an
  /// opacity)
  Q(Array[@pagelayout.GraphicOp])
  /// Q (PDF's restore)
  EndQ
}

///|
/// PDF's q on the page, setting up `setup`: the transformation the page
/// is drawn under changes with it.
fn PageState::save(
  self : PageState,
  setup : Array[@pagelayout.GraphicOp],
) -> Unit {
  self.marks.push((self.items.length(), Q(setup)))
  self.saved_ctms.push(self.ctm)
  match setup {
    [Transform(m)] => self.ctm = self.ctm.after(m)
    _ => ()
  }
}

///|
/// PDF's Q on the page: back to the transformation of its innermost open
/// q (none open: it restores nothing).
fn PageState::restore(self : PageState) -> Unit {
  self.marks.push((self.items.length(), EndQ))
  match self.saved_ctms.pop() {
    Some(m) => self.ctm = m
    None => ()
  }
}

///|
/// The page's items nested as its saves and restores nest them: what lies
/// between a q and its Q in a group, a q still open at the end of the page
/// closed there, a Q with no q open ignored (as PDF readers do). What a
/// group cannot hold (a link) stays on the page, outside.
fn PageState::nested(self : PageState) -> Array[@pagelayout.PageItem] {
  let root : Array[@pagelayout.PageItem] = []
  let open : Array[(Array[@pagelayout.GraphicOp], Array[@pagelayout.GraphicOp])] = []
  let close = fn(
    group : (Array[@pagelayout.GraphicOp], Array[@pagelayout.GraphicOp]),
  ) {
    let ops : Array[@pagelayout.GraphicOp] = [
      Save,
      ..group.0,
      ..group.1,
      Restore,
    ]
    match open.last() {
      Some(parent) => parent.1.append(ops)
      None => root.push(Graphic({ x_pt: 0.0, y_pt: 0.0, ops, }))
    }
  }
  let mut m = 0
  for i in 0..<=self.items.length() {
    while m < self.marks.length() && self.marks[m].0 <= i {
      match self.marks[m].1 {
        Q(setup) => open.push((setup, []))
        EndQ =>
          match open.pop() {
            Some(group) => close(group)
            None => ()
          }
      }
      m += 1
    }
    guard i < self.items.length() else { break }
    let item = self.items[i]
    match (open.last(), item_ops(item)) {
      (Some(group), Some(ops)) => group.1.append(ops)
      _ => root.push(item)
    }
  }
  while open.pop() is Some(group) {
    close(group)
  }
  root
}

///|
/// The page's items cut back to `length` (a dry run's), with the saves and
/// restores among what is cut.
fn PageState::truncate(self : PageState, length : Int) -> Unit {
  self.items.truncate(length)
  while self.marks.last() is Some((at, _)) && at > length {
    self.marks.pop() |> ignore
  }
}

///|
/// The current page's record.
fn Document::page(self : Document) -> PageState {
  self.pages[self.page_index]
}

///|
/// The current page's height (the PDF's y axis is measured up from its
/// bottom).
fn Document::page_h(self : Document) -> Double {
  self.model.pages[self.page_index].height_pt
}

///|
/// Make a page `size` (points, as laid out) right after the current one,
/// where Prawn's `start_new_page` inserts it, and make it current;
/// `geometry` is its size as given and its layout.
fn Document::make_page(
  self : Document,
  size : (Double, Double),
  geometry : ((Double, Double), String),
) -> Unit {
  let from = self.page_index
  let to = from + 1
  self.model.pages.insert(to, {
    width_pt: size.0,
    height_pt: size.1,
    items: [],
  })
  self.page_made(from, to, geometry)
  self.page_index = to
}

///|
/// A page was made, at `to`, from the page at `from` (none for the
/// first): its record starts with that page's graphics state.
fn Document::page_made(
  self : Document,
  from : Int,
  to : Int,
  geometry : ((Double, Double), String),
) -> Unit {
  let source = if from >= 0 && from < self.pages.length() {
    Some(self.pages[from])
  } else {
    None
  }
  let state = match source.bind(p => p.stack.last()) {
    Some(s) => s.copy()
    None => GraphicState::new()
  }
  self.pages.insert(to, {
    items: self.model.pages[to].items,
    stack: [state],
    ctm: @pagelayout.identity,
    path: [],
    geometry,
    marks: [],
    saved_ctms: [],
  })
}
