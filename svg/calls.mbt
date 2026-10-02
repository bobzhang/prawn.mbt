///|
// The drawing calls prawn-svg builds (its call tree of Prawn methods), in
// the SVG's y-down user space. A call with children is a Prawn method
// given a block: its children run inside it.

///|
priv enum PaintKind {
  FillOnly
  StrokeOnly
  FillAndStroke
  EndPath
}

///|
/// A gradient as its user space sees it (prawn-svg's gradient arguments):
/// from one point to another, or from a focus circle of radius `r1` to a
/// centre circle of radius `r2`; `transform` is the gradient transform.
priv struct GradientArgs {
  radial : Bool
  from : (Double, Double)
  r1 : Double
  to : (Double, Double)
  r2 : Double
  stops : Array[(Double, Int)]
  transform : @pagelayout.Matrix
}

///|
/// A `draw_text` call's options.
priv struct TextOptions {
  x : Double?
  y : Double?
  dx : Double
  dy : Double
  size : Double
  anchor : String
  dominant_baseline : String?
  decoration : String?
  rotate : Double?
  stretch_to_width : Double?
  pad_to_width : Double?
}

///|
priv enum Call {
  /// `transformation_matrix`, with or without a block
  Transform(@pagelayout.Matrix, Array[Call]?)
  /// `transparent(fill_opacity, stroke_opacity) { ... }`
  Transparent(Double, Double, Array[Call])
  /// `save_graphics_state { ... }`
  SaveState(Array[Call])
  Save
  Restore
  /// `fill`, `stroke`, `fill_and_stroke`, `end_path` with a block; the flag
  /// is the even-odd fill rule
  Paint(PaintKind, Bool, Array[Call])
  FillColor(Int)
  StrokeColor(Int)
  FillGradient(GradientArgs)
  StrokeGradient(GradientArgs)
  LineWidth(Double)
  CapStyle(@pagelayout.LineCap)
  JoinStyle(@pagelayout.LineJoin)
  Dash(Array[Double])
  Undash
  MoveTo(Double, Double)
  LineTo(Double, Double)
  CurveTo(Double, Double, Double, Double, Double, Double)
  ClosePath
  /// top-left corner, width, height
  Rectangle(Double, Double, Double, Double)
  RoundedRectangle(Double, Double, Double, Double, Double)
  Ellipse(Double, Double, Double, Double)
  Clip
  TextGroup(Array[Call])
  CharacterSpacing(Double, Array[Call])
  TextRenderingMode(String, Array[Call])
  Noop(Array[Call])
  Font(String, String)
  DrawText(String, TextOptions)
  /// an image's bytes and media type, placed at a box: x, y (top), w, h
  Image(Bytes, String, Double, Double, Double, Double)
  /// a nested SVG document (an `<image>` of SVG), drawn at the origin
  SubDocument(SvgDocument)
}

///|
/// A deep copy (prawn-svg duplicates calls it reuses: clip paths, markers).
fn Call::copy(self : Call) -> Call {
  let copy_all = fn(calls : Array[Call]) { calls.map(c => c.copy()) }
  match self {
    Transform(m, Some(children)) => Transform(m, Some(copy_all(children)))
    Transparent(f, s, children) => Transparent(f, s, copy_all(children))
    SaveState(children) => SaveState(copy_all(children))
    Paint(kind, even_odd, children) => Paint(kind, even_odd, copy_all(children))
    TextGroup(children) => TextGroup(copy_all(children))
    CharacterSpacing(v, children) => CharacterSpacing(v, copy_all(children))
    TextRenderingMode(m, children) => TextRenderingMode(m, copy_all(children))
    Noop(children) => Noop(copy_all(children))
    other => other
  }
}

///|
/// The number of calls in `calls`, those in blocks included (what copying
/// them costs).
fn call_count(calls : Array[Call]) -> Int {
  let mut n = 0
  for call in calls {
    n += 1
    if call.block() is Some(children) {
      n += call_count(children)
    }
  }
  n
}

///|
/// The children of a call with a block.
fn Call::block(self : Call) -> Array[Call]? {
  match self {
    Transform(_, Some(children))
    | Transparent(_, _, children)
    | SaveState(children)
    | Paint(_, _, children)
    | TextGroup(children)
    | CharacterSpacing(_, children)
    | TextRenderingMode(_, children)
    | Noop(children) => Some(children)
    _ => None
  }
}

///|
fn translate(x : Double, y : Double) -> @pagelayout.Matrix {
  { a: 1, b: 0, c: 0, d: 1, e: x, f: y, }
}

///|
fn scale(x : Double, y : Double) -> @pagelayout.Matrix {
  { a: x, b: 0, c: 0, d: y, e: 0, f: 0, }
}

///|
fn rotation(degrees : Double) -> @pagelayout.Matrix {
  let r = degrees * @math.PI / 180.0
  {
    a: @math.cos(r),
    b: @math.sin(r),
    c: -@math.sin(r),
    d: @math.cos(r),
    e: 0,
    f: 0,
  }
}

///|
fn is_identity(m : @pagelayout.Matrix) -> Bool {
  m.a == 1.0 &&
  m.b == 0.0 &&
  m.c == 0.0 &&
  m.d == 1.0 &&
  m.e == 0.0 &&
  m.f == 0.0
}

///|
fn invert(m : @pagelayout.Matrix) -> @pagelayout.Matrix? {
  let det = m.a * m.d - m.b * m.c
  if det == 0.0 {
    return None
  }
  let a = m.d / det
  let b = -m.b / det
  let c = -m.c / det
  let d = m.a / det
  Some({ a, b, c, d, e: -(a * m.e + c * m.f), f: -(b * m.e + d * m.f), })
}
