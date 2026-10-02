///|
// `<use>` (prawn-svg's `Elements::Use`, with asciidoctor-pdf's patch that
// treats a `<symbol>` without a viewBox as a plain group).

///|
fn Node::parse_use(self : Node) -> Unit raise Skip {
  guard self.href() is Some(href) else {
    raise SkipWarning("use tag must have an href or xlink:href")
  }
  if !href.has_prefix("#") {
    raise SkipWarning(
      "use tag has an href that is not a reference to an id; this is not supported",
    )
  }
  let id = href.unsafe_substring(start=1, end=href.length())
  let target = match self.doc.elements_by_id.get(id) {
    Some(node) =>
      match node.source {
        Some(source) => Some((node.kind, source))
        None => None
      }
    None =>
      match self.doc.find_raw(id) {
        Some(raw) => kind_of_tag(raw.name).map(kind => (kind, raw))
        None => None
      }
  }
  guard target is Some((kind, source)) else {
    raise SkipWarning("no tag with ID '\{id}' was found, referenced by use tag")
  }
  // a use inside what it references (directly, or through other uses)
  // would expand forever
  if self.doc.active.contains(source.uid) {
    raise SkipWarning(
      "use tag has a circular reference to '#\{id}'; skipping tag",
    )
  }
  let kind = if source.name == "symbol" {
    if source.attr("viewBox") is Some(_) {
      Viewport
    } else {
      Container
    }
  } else {
    kind
  }
  self.use_target = Some((kind, source))
  self.state.inside_use = true
  self.offset = (
    self.attr("x").map(x => self.x_pixels(x)).unwrap_or(0.0),
    self.attr("y").map(y => self.y_pixels(y)).unwrap_or(0.0),
  )
}

///|
fn Node::process_use_child(self : Node) -> Unit {
  guard self.use_target is Some((kind, source)) else { return }
  self.add(Save)
  // a shallow copy: the same children, attributes of its own
  let copy = Element::{ ..source, attributes: source.attributes.copy(), }
  if kind == Viewport {
    copy.set_attr("width", self.attr("width").unwrap_or("100%"))
    copy.set_attr("height", self.attr("height").unwrap_or("100%"))
  }
  let child = Node::new(
    self.doc,
    kind,
    Some(copy),
    self.calls,
    self.state.dup(),
  )
  child.process()
  self.add(Restore)
}
