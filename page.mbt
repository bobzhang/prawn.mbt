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
  mut geometry : ((Double, Double), String)
}

///|
/// The current page's record.
fn Document::page(self : Document) -> PageState {
  self.pages[self.flow.page]
}

///|
/// A page was made, at `to`, from the page at `from` (none for the
/// first): its record starts with that page's graphics state and geometry.
fn Document::page_made(
  self : Document,
  from : Int,
  to : Int,
  first_geometry : ((Double, Double), String),
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
    items: self.flow.model.pages[to].items,
    stack: [state],
    ctm: @pagelayout.identity,
    path: [],
    geometry: match source {
      Some(p) => p.geometry
      None => first_geometry
    },
  })
}
