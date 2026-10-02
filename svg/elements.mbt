///|
// SVG elements as prawn-svg processes them (`Elements::Base` and its
// subclasses): each reads its attributes and properties, then adds calls
// for its transform, opacity, clip path, colours and stroke, a drawing
// call for shapes, its own calls inside that, and its children's, each
// between a save and a restore.

///|
priv enum Kind {
  Root
  Container
  ClipPathElement
  Viewport
  TextElement
  TextComponent
  LineElement
  PolylineElement
  PolygonElement
  CircleElement
  EllipseElement
  RectElement
  PathElement
  UseElement
  ImageElement
  GradientKind
  MarkerElement
  Ignored
} derive(Eq)

///|
fn kind_of_tag(name : String) -> Kind? {
  match name {
    "g" | "symbol" | "defs" | "a" | "switch" => Some(Container)
    "clipPath" => Some(ClipPathElement)
    "svg" => Some(Viewport)
    "text" => Some(TextElement)
    "line" => Some(LineElement)
    "polyline" => Some(PolylineElement)
    "polygon" => Some(PolygonElement)
    "circle" => Some(CircleElement)
    "ellipse" => Some(EllipseElement)
    "rect" => Some(RectElement)
    "path" => Some(PathElement)
    "use" => Some(UseElement)
    "image" => Some(ImageElement)
    "linearGradient" | "radialGradient" => Some(GradientKind)
    "marker" => Some(MarkerElement)
    "style"
    | "title"
    | "desc"
    | "metadata"
    | "foreignObject"
    | "font-face"
    | "filter"
    | "mask" => Some(Ignored)
    _ => None
  }
}

///|
/// prawn-svg's `TextState`: the positions and rotations still to be used
/// by a text element and its spans.
priv struct TextState {
  parent : TextState?
  mut x : Array[Double]
  mut y : Array[Double]
  mut dx : Array[Double]
  mut dy : Array[Double]
  mut rotation : Array[Double]
  mut spacing : Double
  mut mode : String
  mut text_length : Double?
  mut length_adjust : String?
}

///|
fn TextState::new(parent : TextState?) -> TextState {
  {
    parent,
    x: [],
    y: [],
    dx: [],
    dy: [],
    rotation: [],
    spacing: 0,
    mode: "fill",
    text_length: None,
    length_adjust: None,
  }
}

///|
priv struct State {
  mut text : TextState?
  mut preserve_space : Bool
  mut fill_opacity : Double
  mut stroke_opacity : Double
  mut stroke_width : Double
  computed : Properties
  mut viewport : Sizing
  mut inside_use : Bool
  mut inside_clip_path : Bool
}

///|
fn State::new(viewport : Sizing) -> State {
  {
    text: None,
    preserve_space: false,
    fill_opacity: 1,
    stroke_opacity: 1,
    stroke_width: 1,
    computed: Properties::defaults(),
    viewport,
    inside_use: false,
    inside_clip_path: false,
  }
}

///|
fn State::dup(self : State) -> State {
  { ..self, computed: self.computed.copy(), }
}

///|
/// A piece of text in a text element (prawn-svg's `Printable`).
priv struct Printable {
  mut text : String
  leading : Bool
  trailing : Bool
}

///|
priv enum TextItem {
  Printed(Printable)
  Span(Node)
}

///|
/// Skipping an element: quietly, or with a warning.
priv suberror Skip {
  SkipQuietly
  SkipWarning(String)
}

///|
priv struct Node {
  doc : SvgDocument
  kind : Kind
  source : Element?
  name : String
  state : State
  attributes : Map[String, String]
  properties : Properties
  parent_calls : Array[Call]
  mut base_calls : Array[Call]
  mut calls : Array[Call]

  // shapes
  mut commands : Array[PathCommand]
  /// min x, min y, max x, max y in user space, for gradients
  mut bbox : (Double, Double, Double, Double)?
  mut shape : Array[Call]
  // viewports, uses and images
  mut sizing : Sizing?
  mut offset : (Double, Double)
  mut use_target : (Kind, Element)?
  // text
  mut items : Array[TextItem]
}

///|
fn Node::new(
  doc : SvgDocument,
  kind : Kind,
  source : Element?,
  parent_calls : Array[Call],
  state : State,
) -> Node {
  let calls = []
  let node = Node::{
    doc,
    kind,
    source,
    name: source.map(s => s.name).unwrap_or("???"),
    state,
    attributes: {},
    properties: Properties::new(),
    parent_calls,
    base_calls: calls,
    calls,
    commands: [],
    bbox: None,
    shape: [],
    sizing: None,
    offset: (0, 0),
    use_target: None,
    items: [],
  }
  match source {
    Some(s) if !state.inside_use =>
      match s.attr("id") {
        Some(id) => {
          let id = strip(id)
          if id != "" {
            doc.elements_by_id[id] = node
          }
        }
        None => ()
      }
    _ => ()
  }
  node
}

///|
fn Node::warn(self : Node, message : String) -> Unit {
  self.doc.warnings.push(message)
}

///|
fn Node::env(self : Node) -> Environment {
  self.doc.env.unwrap()
}

///|
fn Node::add(self : Node, call : Call) -> Unit {
  self.calls.push(call)
}

///|
/// Add a call with a block, and continue inside it.
fn Node::enter(self : Node, call : Call) -> Unit {
  self.calls.push(call)
  match call.block() {
    Some(children) => self.calls = children
    None => ()
  }
}

///|
fn Node::font_size(self : Node) -> Double {
  self.state.computed.font_size()
}

///|
fn Node::x_pixels(self : Node, value : String) -> Double {
  to_pixels(
    value,
    self.state.viewport.viewport_width,
    font_size=self.font_size(),
  )
}

///|
fn Node::y_pixels(self : Node, value : String) -> Double {
  to_pixels(
    value,
    self.state.viewport.viewport_height,
    font_size=self.font_size(),
  )
}

///|
fn Node::pixels(self : Node, value : String) -> Double {
  to_pixels(
    value,
    self.state.viewport.viewport_diagonal,
    font_size=self.font_size(),
  )
}

///|
fn Node::attr(self : Node, name : String) -> String? {
  self.attributes.get(name)
}

///|
fn Node::href(self : Node) -> String? {
  match self.attr("xlink:href") {
    Some(h) => Some(h)
    None => self.attr("href")
  }
}

///|
fn Node::require_attributes(
  self : Node,
  names : Array[String],
) -> Unit raise Skip {
  let missing = names.filter(n => !self.attributes.contains(n))
  if !missing.is_empty() {
    raise SkipWarning(
      "Must have attributes \{missing.join(", ")} on tag \{self.name}; skipping tag",
    )
  }
}

///|
fn Node::require_positive(
  self : Node,
  values : Array[Double],
) -> Unit raise Skip {
  if values.iter().any(v => v <= 0.0) {
    raise SkipWarning("Invalid attributes on tag \{self.name}; skipping tag")
  }
}

///|
fn Node::is_container(self : Node) -> Bool {
  match self.kind {
    Root
    | Container
    | ClipPathElement
    | Viewport
    | UseElement
    | MarkerElement => true
    _ => false
  }
}

///|
fn Node::set_display_none(self : Node) -> Unit {
  ignore(self.properties.set("display", "none"))
  ignore(self.state.computed.set("display", "none"))
}

///|
/// prawn-svg's `parse_css_declarations` (the `style` attribute): a
/// property name keeps any spaces before its colon, and so goes unknown.
fn parse_style_attribute(style : String) -> Array[(String, String)] {
  let out = []
  let trimmed = strip(style)
  let mut start = 0
  let n = trimmed.length()
  let pieces = []
  for i in 0..<n {
    if trimmed[i] == ';' || trimmed[i] == '$' {
      pieces.push(trimmed.unsafe_substring(start~, end=i))
      start = i + 1
    }
  }
  pieces.push(trimmed.unsafe_substring(start~, end=n))
  for piece in pieces {
    let mut i = 0
    while i < piece.length() && is_ws(piece[i]) {
      i += 1
    }
    if i >= piece.length() {
      continue
    }
    guard find_from(piece, ":", i + 1) is Some(colon) else { continue }
    let name = downcase(piece.unsafe_substring(start=i, end=colon))
    let mut j = colon + 1
    while j < piece.length() && is_ws(piece[j]) {
      j += 1
    }
    if j >= piece.length() {
      continue
    }
    out.push((name, piece.unsafe_substring(start=j, end=piece.length())))
  }
  out
}

///|
fn Node::extract_attributes_and_properties(self : Node) -> Unit {
  guard self.source is Some(source) else { return }
  match self.doc.styles.get(source.uid) {
    Some(declarations) =>
      for d in declarations {
        ignore(self.properties.set(d.0, d.1))
      }
    None => ()
  }
  match source.attr("style") {
    Some(style) =>
      for d in parse_style_attribute(style) {
        ignore(self.properties.set(d.0, d.1))
      }
    None => ()
  }
  for pair in source.attributes {
    if !self.properties.set(pair.0, pair.1) {
      self.attributes[pair.0] = pair.1
    }
  }
  self.state.computed.compute(self.properties)
}

///|
fn Node::process(self : Node) -> Unit {
  let doc = self.doc
  if !doc.spend(1) {
    return
  }
  if doc.depth >= max_depth {
    doc.warn_once(
      "SVG elements are nested too deeply; skipping the deepest ones",
    )
    return
  }
  doc.depth += 1
  let uid = match self.source {
    Some(s) => {
      doc.active.push(s.uid)
      true
    }
    None => false
  }
  defer {
    doc.depth -= 1
    if uid {
      ignore(doc.active.pop())
    }
  }
  if self.kind == TextElement {
    self.process_text()
    return
  }
  self.extract_attributes_and_properties()
  self.parse_and_apply()
}

///|
fn Node::parse_and_apply(self : Node) -> Unit {
  try {
    self.parse_xml_space()
    self.parse()
    self.apply_standard_attributes()
    self.apply()
    if self.is_container() {
      self.process_children()
    }
    if self.state.computed.get("display") != Some("none") {
      self.parent_calls.append(self.base_calls)
    }
  } catch {
    SkipQuietly => ()
    SkipWarning(message) => self.warn(message)
  }
}

///|
fn Node::parse_xml_space(self : Node) -> Unit {
  match self.attr("xml:space") {
    Some("preserve") => self.state.preserve_space = true
    Some("default") => self.state.preserve_space = false
    _ => ()
  }
}

///|
/// The SVG child elements (in no namespace or the SVG one).
fn svg_children(source : Element) -> Array[Element] {
  source
  .elements()
  .filter(e => {
    e.namespace_uri == "http://www.w3.org/2000/svg" || e.namespace_uri == ""
  })
}

///|
fn Node::process_children(self : Node) -> Unit {
  guard self.source is Some(source) else { return }
  if self.kind == UseElement {
    self.process_use_child()
    return
  }
  for child in svg_children(source) {
    match kind_of_tag(child.name) {
      Some(kind) => {
        self.add(Save)
        let node = Node::new(
          self.doc,
          kind,
          Some(child),
          self.calls,
          self.state.dup(),
        )
        node.process()
        self.add(Restore)
      }
      None => self.warn("Unknown tag '\{child.name}'; ignoring")
    }
  }
}

///|
/// The element a `url(#id)` reference names, when it is a `tag` element.
fn Node::url_reference(self : Node, value : String?, tag : String) -> Node? {
  guard value is Some(v) else { return None }
  let v = strip(v)
  guard downcase(v).has_prefix("url(") && v.has_suffix(")") else { return None }
  let inner = strip(v.unsafe_substring(start=4, end=v.length() - 1))
  guard inner.has_prefix("#") && !inner.contains_any(chars=" \t\n") else {
    return None
  }
  match
    self.doc.elements_by_id.get(
      inner.unsafe_substring(start=1, end=inner.length()),
    ) {
    Some(node) if node.name == tag => Some(node)
    _ => None
  }
}

///|
fn clamp01(v : Double) -> Double {
  @cmp.maximum(0.0, @cmp.minimum(1.0, v))
}

///|
fn Node::apply_transform(self : Node) -> Unit {
  guard self.attr("transform") is Some(text) else { return }
  let m = parse_transform(text, self.doc.warnings)
  if !is_identity(m) {
    self.enter(Transform(m, Some([])))
  }
}

///|
fn Node::apply_opacity(self : Node) -> Unit {
  let get = fn(name : String) {
    self.properties.get(name).map(v => clamp01(ruby_to_f(v)))
  }
  let opacity = get("opacity")
  let fill = get("fill-opacity")
  let stroke = get("stroke-opacity")
  if opacity is None && fill is None && stroke is None {
    return
  }
  let o = opacity.unwrap_or(1.0)
  self.state.fill_opacity *= @cmp.minimum(o, fill.unwrap_or(1.0))
  self.state.stroke_opacity *= @cmp.minimum(o, stroke.unwrap_or(1.0))
  self.enter(
    Transparent(self.state.fill_opacity, self.state.stroke_opacity, []),
  )
}

///|
fn Node::apply_clip_path(self : Node) -> Unit {
  guard self.properties.get("clip-path") is Some(value) && value != "none" else {
    return
  }
  match self.url_reference(Some(value), "clipPath") {
    None => self.warn("Could not resolve clip-path URI to a clipPath element")
    Some(clip) => {
      if !self.doc.spend(call_count(clip.base_calls)) {
        return
      }
      self.enter(SaveState([]))
      for call in clip.base_calls {
        self.add(call.copy())
      }
      self.add(Clip)
    }
  }
}

///|
fn Node::apply_colors(self : Node) -> Unit {
  for kind in ["fill", "stroke"] {
    guard self.properties.get(kind) is Some(value) &&
      value != "inherit" &&
      value != "none" else {
      continue
    }
    let value = if value == "currentColor" {
      self.state.computed.get("color").unwrap_or("")
    } else {
      value
    }
    let mut success = false
    for candidate in parse_color(value) {
      match candidate {
        Rgb(rgb) => {
          self.add(
            if kind == "fill" {
              FillColor(rgb)
            } else {
              StrokeColor(rgb)
            },
          )
          success = true
        }
        Url(url) =>
          if url.has_prefix("#") {
            match
              self.doc.gradient(url.unsafe_substring(start=1, end=url.length())) {
              Some(gradient) =>
                match gradient.arguments(self) {
                  Some(args) => {
                    self.add(
                      if kind == "fill" {
                        FillGradient(args)
                      } else {
                        StrokeGradient(args)
                      },
                    )
                    success = true
                  }
                  None => ()
                }
              None => ()
            }
          }
      }
      if success {
        break
      }
    }
    if !success {
      ignore(self.state.computed.set(kind, "none"))
    }
  }
}

///|
fn Node::apply_stroke(self : Node) -> Unit {
  match self.properties.get("stroke-width") {
    Some(w) => {
      let width = self.pixels(w)
      self.state.stroke_width = width
      self.add(LineWidth(width))
    }
    None => ()
  }
  match self.properties.get("stroke-linecap") {
    Some("inherit") | None => ()
    Some(cap) =>
      self.add(
        CapStyle(
          match cap {
            "round" => RoundCap
            "square" => SquareCap
            _ => ButtCap
          },
        ),
      )
  }
  match self.properties.get("stroke-linejoin") {
    Some("inherit") | None => ()
    Some(join) =>
      self.add(
        JoinStyle(
          match join {
            "round" => RoundJoin
            "bevel" => BevelJoin
            _ => MiterJoin
          },
        ),
      )
  }
  match self.properties.get("stroke-dasharray") {
    None | Some("inherit") => ()
    Some("none") => self.add(Undash)
    Some(dasharray) => {
      let mut parts = split_comma_wsp(dasharray)
      if parts.length() % 2 == 1 {
        parts = [..parts, ..parts]
      }
      let numbers = parts.map(p => self.pixels(p))
      if numbers.iter().any(n => n < 0.0) {
        self.warn(
          "stroke-dasharray cannot have negative numbers; treating as 'none'",
        )
        self.add(Undash)
      } else if numbers.fold(init=0.0, (a, b) => a + b) == 0.0 {
        self.add(Undash)
      } else {
        self.add(Dash(numbers))
      }
    }
  }
}

///|
fn Node::drawable(self : Node) -> Bool {
  !self.is_container() && self.kind != TextElement && self.kind != TextComponent
}

///|
fn Node::apply_drawing_call(self : Node) -> Unit {
  if self.state.inside_clip_path || !self.drawable() {
    return
  }
  let fill = self.state.computed.get("fill") != Some("none")
  let stroke = self.state.computed.get("stroke") != Some("none")
  let even_odd = self.state.computed.get("fill-rule") == Some("evenodd")
  if fill {
    self.enter(
      Paint(if stroke { FillAndStroke } else { FillOnly }, even_odd, []),
    )
  } else if stroke {
    self.enter(Paint(StrokeOnly, false, []))
  } else {
    self.enter(Paint(EndPath, false, []))
  }
}

///|
fn Node::apply_standard_attributes(self : Node) -> Unit {
  self.apply_transform()
  self.apply_opacity()
  self.apply_clip_path()
  self.apply_colors()
  self.apply_stroke()
  self.apply_drawing_call()
}

///|
fn Node::overflow_hidden(self : Node) -> Bool {
  match self.state.computed.get("overflow") {
    Some("hidden" | "scroll") => true
    _ => false
  }
}

///|
/// Kind-specific reading of the element.
fn Node::parse(self : Node) -> Unit raise Skip {
  match self.kind {
    Root => self.state.viewport = self.doc.sizing
    Container =>
      if (self.name == "symbol" && !self.state.inside_use) ||
        self.name == "defs" {
        self.set_display_none()
      }
    ClipPathElement => {
      self.state.inside_clip_path = true
      self.set_display_none()
    }
    MarkerElement => self.set_display_none()
    Ignored => raise SkipQuietly
    Viewport => {
      let parent = self.state.viewport
      let sizing = Sizing::new(
        (parent.viewport_width, parent.viewport_height),
        width?=self.attr("width"),
        height?=self.attr("height"),
        view_box?=self.attr("viewBox"),
        preserve_aspect_ratio?=self.attr("preserveAspectRatio"),
      )
      sizing.calculate()
      self.offset = (
        self.x_pixels(self.attr("x").unwrap_or("0")),
        self.y_pixels(self.attr("y").unwrap_or("0")),
      )
      self.sizing = Some(sizing)
      self.state.viewport = sizing
    }
    LineElement => {
      ignore(self.state.computed.set("fill", "none"))
      let get = fn(name) { self.attr(name).unwrap_or("0") }
      self.commands = [
        Move(self.x_pixels(get("x1")), self.y_pixels(get("y1"))),
        Line(self.x_pixels(get("x2")), self.y_pixels(get("y2"))),
      ]
    }
    PolylineElement | PolygonElement => {
      self.require_attributes(["points"])
      let points = self.parse_points(self.attr("points").unwrap_or(""))
      let commands = [Move(points[0].0, points[0].1)]
      for p in points[1:] {
        commands.push(Line(p.0, p.1))
      }
      if self.kind == PolygonElement {
        commands.push(ClosePath(points[0].0, points[0].1))
      }
      self.commands = commands
    }
    CircleElement => {
      self.require_attributes(["r"])
      let x = self.x_pixels(self.attr("cx").unwrap_or("0"))
      let y = self.y_pixels(self.attr("cy").unwrap_or("0"))
      let r = self.pixels(self.attr("r").unwrap_or("0"))
      self.require_positive([r])
      self.shape = [Ellipse(x, y, r, r)]
      self.bbox = Some((x - r, y - r, x + r, y + r))
    }
    EllipseElement => {
      self.require_attributes(["rx", "ry"])
      let x = self.x_pixels(self.attr("cx").unwrap_or("0"))
      let y = self.y_pixels(self.attr("cy").unwrap_or("0"))
      let rx = self.x_pixels(self.attr("rx").unwrap_or("0"))
      let ry = self.y_pixels(self.attr("ry").unwrap_or("0"))
      self.require_positive([rx, ry])
      self.shape = [Ellipse(x, y, rx, ry)]
      self.bbox = Some((x - rx, y - ry, x + rx, y + ry))
    }
    RectElement => {
      self.require_attributes(["width", "height"])
      let x = self.x_pixels(self.attr("x").unwrap_or("0"))
      let y = self.y_pixels(self.attr("y").unwrap_or("0"))
      let w = self.x_pixels(self.attr("width").unwrap_or("0"))
      let h = self.y_pixels(self.attr("height").unwrap_or("0"))
      self.require_positive([w, h])
      let radius = match self.attr("rx") {
        Some(rx) => Some(self.x_pixels(rx))
        None => self.attr("ry").map(ry => self.y_pixels(ry))
      }
      self.shape = match radius {
        Some(r) => {
          let r = @cmp.maximum(0.0, @cmp.minimum(r, @cmp.minimum(w, h) / 2.0))
          [RoundedRectangle(x, y, w, h, r)]
        }
        None => [Rectangle(x, y, w, h)]
      }
      self.bbox = Some((x, y, x + w, y + h))
    }
    PathElement => {
      self.require_attributes(["d"])
      match parse_path_data(self.attr("d").unwrap_or("")) {
        Some(commands) => self.commands = commands
        None =>
          raise SkipWarning("Invalid/unsupported syntax for SVG path data")
      }
    }
    UseElement => self.parse_use()
    ImageElement => self.parse_image()
    GradientKind => {
      match self.source {
        Some(source) => self.doc.register_gradient(self, source)
        None => ()
      }
      raise SkipQuietly
    }
    TextElement | TextComponent => ()
  }
  if !self.commands.is_empty() {
    self.bbox = commands_bbox(self.commands)
  }
}

///|
/// The bounding box of path commands' end points (prawn-svg's
/// `Pathable#bounding_box`).
fn commands_bbox(
  commands : Array[PathCommand],
) -> (Double, Double, Double, Double)? {
  guard commands.length() > 0 else { return None }
  let (x0, y0) = commands[0].destination()
  let mut minx = x0
  let mut maxx = x0
  let mut miny = y0
  let mut maxy = y0
  for c in commands {
    let (x, y) = c.destination()
    minx = @cmp.minimum(minx, x)
    maxx = @cmp.maximum(maxx, x)
    miny = @cmp.minimum(miny, y)
    maxy = @cmp.maximum(maxy, y)
  }
  Some((minx, miny, maxx, maxy))
}

///|
fn Node::parse_points(
  self : Node,
  text : String,
) -> Array[(Double, Double)] raise Skip {
  // `(\d)-(\d)` gets a space: "1-2" is two numbers
  let sb = StringBuilder()
  let s = strip(text)
  for i in 0..<s.length() {
    let c = s[i]
    if c == '-' &&
      i > 0 &&
      s[i - 1] >= '0' &&
      s[i - 1] <= '9' &&
      i + 1 < s.length() &&
      s[i + 1] >= '0' &&
      s[i + 1] <= '9' {
      sb.write_char(' ')
    }
    sb.write_char(c.unsafe_to_char())
  }
  let values = split_comma_wsp(sb.to_string()).map(ruby_to_f)
  if values.length() % 2 == 1 {
    self.warn(
      "points attribute has an odd number of points; ignoring the last one",
    )
    ignore(values.pop())
  }
  if values.is_empty() {
    raise SkipQuietly
  }
  let out = []
  for i = 0; i + 1 < values.length(); i = i + 2 {
    out.push((values[i], values[i + 1]))
  }
  out
}

///|
fn Node::apply_commands(self : Node) -> Unit {
  for c in self.commands {
    match c {
      Move(x, y) => self.add(MoveTo(x, y))
      Line(x, y) => self.add(LineTo(x, y))
      ClosePath(_, _) => self.add(ClosePath)
      Curve(x, y, x1, y1, x2, y2) => self.add(CurveTo(x1, y1, x2, y2, x, y))
    }
  }
}

///|
/// Kind-specific calls.
fn Node::apply(self : Node) -> Unit {
  match self.kind {
    Root => {
      match self.properties.get("fill") {
        None | Some("inherit" | "none" | "currentColor") =>
          self.add(FillColor(0))
        _ => ()
      }
      let sizing = self.doc.sizing
      self.add(Transform(scale(sizing.x_scale, sizing.y_scale), None))
      self.add(Transform(translate(-sizing.x_offset, -sizing.y_offset), None))
    }
    Viewport => {
      guard self.sizing is Some(sizing) else { return }
      let (x, y) = self.offset
      if x != 0.0 || y != 0.0 {
        self.add(Transform(translate(x, y), None))
      }
      if self.overflow_hidden() {
        self.add(Rectangle(0, 0, sizing.output_width, sizing.output_height))
        self.add(Clip)
      }
      self.add(Transform(scale(sizing.x_scale, sizing.y_scale), None))
      self.add(Transform(translate(-sizing.x_offset, -sizing.y_offset), None))
    }
    LineElement | PolylineElement | PolygonElement | PathElement => {
      self.apply_commands()
      self.apply_markers()
    }
    CircleElement | EllipseElement | RectElement =>
      for call in self.shape {
        self.add(call)
      }
    UseElement => {
      let (x, y) = self.offset
      if self.attr("x") is Some(_) || self.attr("y") is Some(_) {
        self.enter(Transform(translate(x, y), Some([])))
      }
    }
    ImageElement => self.apply_image()
    _ => ()
  }
}
