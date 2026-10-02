///|
// Gradients (prawn-svg's `Elements::Gradient` and `Gradients`): read when
// the tree reaches them or when a paint first names them, then turned into
// gradient arguments for each element they paint.

///|
priv struct GradientElement {
  radial : Bool
  bounding_box : Bool
  /// linear: x1, y1, x2, y2; radial: cx, cy, fx, fy, r
  coords : Array[Double]
  stops : Array[(Double, Int)]
  transform : @pagelayout.Matrix?
}

///|
/// A number between 0 and 1 (`parse_zero_to_one`): a percentage divided by
/// 100, `default` when empty.
fn zero_to_one(value : String?, default : Double) -> Double {
  let s = strip(value.unwrap_or(""))
  if s == "" {
    return default
  }
  let mut v = ruby_to_f(s)
  if s.has_suffix("%") {
    v = v / 100.0
  }
  clamp01(v)
}

///|
/// Read a gradient element (a `Node` of kind `GradientKind`, its attributes
/// extracted) and register it under its id.
fn SvgDocument::register_gradient(
  self : SvgDocument,
  node : Node,
  source : Element,
) -> Unit raise Skip {
  guard node.attr("id") is Some(id) else { raise SkipQuietly }
  // the gradient it inherits from must not lead back to it
  self.resolving.push(strip(id))
  defer ignore(self.resolving.pop())
  let parent = match node.href() {
    Some(h) if h.has_prefix("#") =>
      self.gradient(h.unsafe_substring(start=1, end=h.length()))
    _ => None
  }
  let radial = source.name == "radialGradient"
  let bounding_box = node.attr("gradientUnits") != Some("userSpaceOnUse")
  let transform = node
    .attr("gradientTransform")
    .map(t => parse_transform(t, self.warnings))
  match node.attr("spreadMethod") {
    Some(spread) if spread != "pad" =>
      node.warn(
        "prawn-svg only currently supports the 'pad' spreadMethod attribute value",
      )
    _ => ()
  }
  let a = fn(name) { node.attr(name) }
  let coords = match (radial, bounding_box) {
    (false, true) =>
      [
        zero_to_one(a("x1"), 0),
        zero_to_one(a("y1"), 0),
        zero_to_one(a("x2"), 1),
        zero_to_one(a("y2"), 0),
      ]
    (false, false) =>
      [
        node.x_pixels(a("x1").unwrap_or("0")),
        node.y_pixels(a("y1").unwrap_or("0")),
        node.x_pixels(a("x2").unwrap_or("0")),
        node.y_pixels(a("y2").unwrap_or("0")),
      ]
    (true, true) => {
      let cx = zero_to_one(a("cx"), 0.5)
      let cy = zero_to_one(a("cy"), 0.5)
      [
        cx,
        cy,
        zero_to_one(a("fx"), cx),
        zero_to_one(a("fy"), cy),
        zero_to_one(a("r"), 0.5),
      ]
    }
    (true, false) => {
      let cx = a("cx").unwrap_or("50%")
      let cy = a("cy").unwrap_or("50%")
      [
        node.x_pixels(cx),
        node.y_pixels(cy),
        node.x_pixels(a("fx").unwrap_or(a("cx").unwrap_or("0"))),
        node.y_pixels(a("fy").unwrap_or(a("cy").unwrap_or("0"))),
        node.pixels(a("r").unwrap_or("50%")),
      ]
    }
  }
  // the stops: `stop` children with an offset, each offset at least the
  // previous one, the colour their `stop-color` gives (black by default)
  let stops : Array[(Double, Int)] = []
  for child in source.elements() {
    guard child.name == "stop" && child.attr("offset") is Some(offset) else {
      continue
    }
    let stop = Node::new(
      self,
      Ignored,
      Some(child),
      [],
      State::new(self.sizing),
    )
    stop.extract_attributes_and_properties()
    let mut position = zero_to_one(Some(offset), 0)
    match stops.last() {
      Some((last, _)) if last > position => position = last
      _ => ()
    }
    match css_color(stop.properties.get("stop-color")) {
      Some(color) => stops.push((position, color))
      None => ()
    }
  }
  let stops = if stops.is_empty() {
    match parent {
      Some(p) if !p.stops.is_empty() => p.stops
      _ => raise SkipWarning("gradient does not have any valid stops")
    }
  } else {
    if stops[0].0 > 0.0 {
      stops.insert(0, (0.0, stops[0].1))
    }
    if stops[stops.length() - 1].0 < 1.0 {
      stops.push((1.0, stops[stops.length() - 1].1))
    }
    stops
  }
  self.gradients[id] = { radial, bounding_box, coords, stops, transform, }
}

///|
/// The gradient registered under `id`, reading it from the tree if it has
/// not been reached yet (prawn-svg's `Gradients#[]`).
fn SvgDocument::gradient(self : SvgDocument, id : String) -> GradientElement? {
  let id = strip(id)
  if id == "" {
    return None
  }
  match self.gradients.get(id) {
    Some(g) => return Some(g)
    None => ()
  }
  if self.resolving.contains(id) {
    self.warnings.push(
      "gradient has a circular reference to '#\{id}'; ignoring it",
    )
    return None
  }
  guard self.find_raw(id) is Some(raw) &&
    (raw.name == "linearGradient" || raw.name == "radialGradient") else {
    return None
  }
  let node = Node::new(
    self,
    GradientKind,
    Some(raw),
    [],
    State::new(self.sizing),
  )
  node.process()
  self.gradients.get(id)
}

///|
/// The arguments to paint `element` with (`gradient_arguments`); None when
/// its bounding box is needed but it has none.
fn GradientElement::arguments(
  self : GradientElement,
  element : Node,
) -> GradientArgs? {
  let c = self.coords
  let (from, r1, to, r2) = if self.bounding_box {
    guard element.bbox is Some((x1, y1, x2, y2)) else { return None }
    let width = x2 - x1
    let height = y2 - y1
    if self.radial {
      let hypot = (width * width + height * height).sqrt()
      (
        (x1 + width * c[2], y1 + height * c[3]),
        0.0,
        (x1 + width * c[0], y1 + height * c[1]),
        c[4] * hypot,
      )
    } else {
      (
        (x1 + width * c[0], y1 + height * c[1]),
        0.0,
        (x1 + width * c[2], y1 + height * c[3]),
        0.0,
      )
    }
  } else if self.radial {
    ((c[2], c[3]), 0.0, (c[0], c[1]), c[4])
  } else {
    ((c[0], c[1]), 0.0, (c[2], c[3]), 0.0)
  }
  Some({
    radial: self.radial,
    from,
    r1,
    to,
    r2,
    stops: self.stops,
    transform: self.transform.unwrap_or(@pagelayout.identity),
  })
}
