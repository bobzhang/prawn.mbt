///|
// Prawn's graphics (`Prawn::Graphics`): the graphics state, paths built in
// Prawn's coordinates (y up, relative to the bounds' bottom left), and
// painting them, drawn as pagelayout graphics in page space.

///|

///|
/// The graphics state Prawn keeps (`PDF::Core::GraphicState`).
priv struct GraphicState {
  mut fill : Color
  mut stroke : Color
  mut line_width : Double
  mut cap : @pagelayout.LineCap
  mut join : @pagelayout.LineJoin
  mut dash : Array[Double]
  mut dash_phase : Double
}

///|
fn GraphicState::new() -> GraphicState {
  {
    fill: Color::rgb(0, 0, 0),
    stroke: Color::rgb(0, 0, 0),
    line_width: 1.0,
    cap: ButtCap,
    join: MiterJoin,
    dash: [],
    dash_phase: 0.0,
  }
}

///|
fn GraphicState::copy(self : GraphicState) -> GraphicState {
  { ..self, dash: self.dash.copy(), }
}

///|
/// The current page's graphics state (each page has its own; see
/// `Document::new`).
fn Document::gs(self : Document) -> GraphicState {
  let stack = self.page().stack
  // a stack restored past its bottom (a block that started on another
  // page) starts again from the defaults
  if stack.is_empty() {
    stack.push(GraphicState::new())
  }
  stack[stack.length() - 1]
}

///|
/// The current page's path being built.
fn Document::path(self : Document) -> Array[@pagelayout.PathSegment] {
  self.page().path
}

///|
/// Adds a segment to the current page's path (a close with nothing to
/// close does nothing).
fn Document::add_segment(
  self : Document,
  segment : @pagelayout.PathSegment,
) -> Unit {
  // content too (pdf-core's `add_content` makes a graphics state)
  self.gs() |> ignore
  let path = self.path()
  if segment is Close && path.is_empty() {
    return
  }
  // kept as drawn on the page: Prawn's path is in the coordinates of the
  // transformation it is built under
  path.append(map_segment(segment, self.page().ctm))
}

///|
/// Prawn's `KAPPA`: the control point distance, as a fraction of the
/// radius, of the four Bézier curves that make a circle.
let kappa : Double = 4.0 * ((2.0.sqrt() - 1.0) / 3.0)

///|
/// A colour Prawn names in hex (`"FFCC00"`: six digits, no `#`).
pub fn color_of_hex(hex : String) -> Color raise PrawnError {
  let bad = ArgumentError("Unknown type of color: \"\{hex}\"")
  guard hex.length() == 6 else { raise bad }
  let digit = fn(c : Char) -> Int? {
    match c {
      '0'..='9' => Some(c.to_int() - '0'.to_int())
      'a'..='f' => Some(c.to_int() - 'a'.to_int() + 10)
      'A'..='F' => Some(c.to_int() - 'A'.to_int() + 10)
      _ => None
    }
  }
  let parts : Array[Int] = []
  for i in 0..<3 {
    guard digit(hex[2 * i].unsafe_to_char()) is Some(hi) &&
      digit(hex[2 * i + 1].unsafe_to_char()) is Some(lo) else {
      raise bad
    }
    parts.push(hi * 16 + lo)
  }
  Color::rgb(parts[0], parts[1], parts[2])
}

///|
/// Prawn's `fill_color=`: what fills and text are painted with.
pub fn Document::set_fill_color(self : Document, color : Color) -> Unit {
  self.gs().fill = color
}

///|
/// Prawn's `stroke_color=`.
pub fn Document::set_stroke_color(self : Document, color : Color) -> Unit {
  self.gs().stroke = color
}

///|
/// Prawn's `line_width=`.
pub fn Document::set_line_width(self : Document, width : Double) -> Unit {
  self.gs().line_width = width
}

///|
/// Prawn's `cap_style=`.
pub fn Document::set_cap_style(
  self : Document,
  cap : @pagelayout.LineCap,
) -> Unit {
  self.gs().cap = cap
}

///|
/// Prawn's `join_style=`.
pub fn Document::set_join_style(
  self : Document,
  join : @pagelayout.LineJoin,
) -> Unit {
  self.gs().join = join
}

///|
/// Prawn's `dash`: dashes `lengths` long (one length: dashes that long with
/// gaps `space`, by default as long), starting `phase` into the pattern.
pub fn Document::dash(
  self : Document,
  lengths : Array[Double],
  space? : Double,
  phase? : Double = 0.0,
) -> Unit raise PrawnError {
  if lengths.iter().all(x => x == 0.0) {
    raise ArgumentError(
      "Zero length dashes are invalid. Call #undash to disable dashes.",
    )
  }
  if lengths.iter().any(x => x < 0.0) {
    raise ArgumentError("Negative numbers are not allowed for dash lengths.")
  }
  self.gs().dash = match lengths {
    [length] => [length, space.unwrap_or(length)]
    _ => lengths
  }
  self.gs().dash_phase = phase
}

///|
/// Prawn's `undash`.
pub fn Document::undash(self : Document) -> Unit {
  self.gs().dash = []
  self.gs().dash_phase = 0.0
}

///|
/// A point of the bounds (Prawn's `map_to_absolute`) on the page, in
/// pagelayout's space (y down from the page's top).
fn Document::page_point(
  self : Document,
  x : Double,
  y : Double,
) -> (Double, Double) {
  let box = self.current_box()
  let bottom = box.top - box.height_at(self.y())
  (box.left + x, self.page_h() - (bottom + y))
}

///|
/// Prawn's `move_to`.
pub fn Document::move_to(self : Document, x : Double, y : Double) -> Unit {
  let (px, py) = self.page_point(x, y)
  self.add_segment(MoveTo(px, py))
}

///|
/// Prawn's `line_to`.
pub fn Document::line_to(self : Document, x : Double, y : Double) -> Unit {
  let (px, py) = self.page_point(x, y)
  self.add_segment(LineTo(px, py))
}

///|
/// Prawn's `curve_to`: a Bézier curve to `dest` with control points
/// `bounds`.
pub fn Document::curve_to(
  self : Document,
  dest : (Double, Double),
  bounds : ((Double, Double), (Double, Double)),
) -> Unit {
  let (x1, y1) = self.page_point(bounds.0.0, bounds.0.1)
  let (x2, y2) = self.page_point(bounds.1.0, bounds.1.1)
  let (x3, y3) = self.page_point(dest.0, dest.1)
  self.add_segment(CurveTo(x1, y1, x2, y2, x3, y3))
}

///|
/// Prawn's `rectangle`: `point` is the top left corner.
pub fn Document::rectangle(
  self : Document,
  point : (Double, Double),
  width : Double,
  height : Double,
) -> Unit {
  let (x, y) = self.page_point(point.0, point.1)
  self.add_segment(Rectangle(x, y, width, height))
}

///|
/// Prawn's `line`.
pub fn Document::line(
  self : Document,
  from : (Double, Double),
  to : (Double, Double),
) -> Unit {
  self.move_to(from.0, from.1)
  self.line_to(to.0, to.1)
}

///|
/// Prawn's `horizontal_line`: from `x1` to `x2` at `at` (by default the
/// cursor).
pub fn Document::horizontal_line(
  self : Document,
  x1 : Double,
  x2 : Double,
  at? : Double,
) -> Unit {
  let y = at.unwrap_or(self.cursor())
  self.line((x1, y), (x2, y))
}

///|
/// Prawn's `horizontal_rule`: across the bounds at the cursor.
pub fn Document::horizontal_rule(self : Document) -> Unit {
  self.horizontal_line(0.0, self.bounds().width)
}

///|
/// Prawn's `vertical_line`.
pub fn Document::vertical_line(
  self : Document,
  y1 : Double,
  y2 : Double,
  at~ : Double,
) -> Unit {
  self.line((at, y1), (at, y2))
}

///|
/// Prawn's `curve`.
pub fn Document::curve(
  self : Document,
  origin : (Double, Double),
  dest : (Double, Double),
  bounds : ((Double, Double), (Double, Double)),
) -> Unit {
  self.move_to(origin.0, origin.1)
  self.curve_to(dest, bounds)
}

///|
/// Prawn's `ellipse`: four Bézier curves around `center`, then a move to
/// the center.
pub fn Document::ellipse(
  self : Document,
  center : (Double, Double),
  r1 : Double,
  r2? : Double,
) -> Unit {
  let r2 = r2.unwrap_or(r1)
  let (x, y) = center
  let l1 = r1 * kappa
  let l2 = r2 * kappa
  self.move_to(x + r1, y)
  self.curve_to((x, y + r2), ((x + r1, y + l2), (x + l1, y + r2)))
  self.curve_to((x - r1, y), ((x - l1, y + r2), (x - r1, y + l2)))
  self.curve_to((x, y - r2), ((x - r1, y - l2), (x - l1, y - r2)))
  self.curve_to((x + r1, y), ((x + l1, y - r2), (x + r1, y - l2)))
  self.move_to(x, y)
}

///|
/// Prawn's `circle`.
pub fn Document::circle(
  self : Document,
  center : (Double, Double),
  radius : Double,
) -> Unit {
  self.ellipse(center, radius, r2=radius)
}

///|
/// Prawn's `polygon`: closed.
pub fn Document::polygon(
  self : Document,
  points : Array[(Double, Double)],
) -> Unit {
  guard points.length() > 0 else { return }
  self.move_to(points[0].0, points[0].1)
  for p in points[1:] {
    self.line_to(p.0, p.1)
  }
  self.line_to(points[0].0, points[0].1)
  self.add_segment(Close)
}

///|
/// Prawn's `point_on_line`: the point `distance` short of the end of the
/// line from `p0` to `p1`.
fn point_on_line(
  distance : Double,
  p0 : (Double, Double),
  p1 : (Double, Double),
) -> (Double, Double) {
  let (x0, y0) = p0
  let (x1, y1) = p1
  let length = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).sqrt()
  let p = (length - distance) / length
  (x0 + p * (x1 - x0), y0 + p * (y1 - y0))
}

///|
/// Prawn's `rounded_vertex`.
fn Document::rounded_vertex(
  self : Document,
  radius : Double,
  p0 : (Double, Double),
  p1 : (Double, Double),
  p2 : (Double, Double),
) -> Unit {
  let radial1 = point_on_line(radius, p0, p1)
  let bezier1 = point_on_line(radius - radius * kappa, p0, p1)
  let radial2 = point_on_line(radius, p2, p1)
  let bezier2 = point_on_line(radius - radius * kappa, p2, p1)
  self.line_to(radial1.0, radial1.1)
  self.curve_to(radial2, (bezier1, bezier2))
}

///|
/// Prawn's `rounded_polygon`: corners rounded with `radius`, closed.
pub fn Document::rounded_polygon(
  self : Document,
  radius : Double,
  points : Array[(Double, Double)],
) -> Unit {
  guard points.length() >= 2 else { return }
  let start = point_on_line(radius, points[1], points[0])
  self.move_to(start.0, start.1)
  let ring = [..points, points[0], points[1]]
  for i in 0..<points.length() {
    self.rounded_vertex(radius, ring[i], ring[i + 1], ring[i + 2])
  }
  self.add_segment(Close)
}

///|
/// Prawn's `rounded_rectangle`.
pub fn Document::rounded_rectangle(
  self : Document,
  point : (Double, Double),
  width : Double,
  height : Double,
  radius : Double,
) -> Unit {
  let (x, y) = point
  self.rounded_polygon(radius, [
    point,
    (x + width, y),
    (x + width, y - height),
    (x, y - height),
  ])
}

///|
/// Prawn's `close_path`.
pub fn Document::close_path(self : Document) -> Unit {
  self.add_segment(Close)
}

///|
/// Paints the path built so far and starts a new one.
fn Document::paint(
  self : Document,
  fill? : Bool = false,
  stroke? : Bool = false,
  even_odd? : Bool = false,
) -> Unit {
  // the paint operator is content: pdf-core makes a graphics state for it
  // when the stack has none (`add_content`), even for an empty path
  self.gs() |> ignore
  // in the coordinates of the transformation it is painted under (the
  // group around it applies that)
  let back = inverse(self.page().ctm)
  let segments = self
    .path()
    .iter()
    .flat_map(s => map_segment(s, back).iter())
    .to_array()
  self.path().clear()
  guard segments.length() > 0 else { return }
  let gs = self.gs()
  self.page().items.push(
    Graphic({
      x_pt: 0.0,
      y_pt: 0.0,
      ops: [
        Path({
          segments,
          fill: if fill {
            Some(Solid(gs.fill))
          } else {
            None
          },
          fill_rule: if even_odd {
            EvenOdd
          } else {
            NonZero
          },
          stroke: if stroke {
            Some(Solid(gs.stroke))
          } else {
            None
          },
          stroke_style: {
            width: if gs.line_width == 0.0 {
              Hairline
            } else {
              Width(gs.line_width)
            },
            cap: gs.cap,
            join: gs.join,
            miter_limit: 10.0,
            dash: gs.dash.copy(),
            dash_phase: gs.dash_phase,
          },
        }),
      ],
    }),
  )
}

///|
/// Prawn's `stroke`.
pub fn Document::stroke(self : Document) -> Unit {
  self.paint(stroke=true)
}

///|
/// Prawn's `close_and_stroke`.
pub fn Document::close_and_stroke(self : Document) -> Unit {
  self.add_segment(Close)
  self.paint(stroke=true)
}

///|
/// Prawn's `fill`.
pub fn Document::fill(self : Document, even_odd? : Bool = false) -> Unit {
  self.paint(fill=true, even_odd~)
}

///|
/// Prawn's `fill_and_stroke`: PDF's `b`, which closes the current
/// subpath before it fills and strokes.
pub fn Document::fill_and_stroke(
  self : Document,
  even_odd? : Bool = false,
) -> Unit {
  if !(self.path().last() is Some(Close)) {
    self.add_segment(Close)
  }
  self.paint(fill=true, stroke=true, even_odd~)
}

///|
/// Prawn's `stroke_bounds`.
pub fn Document::stroke_bounds(self : Document) -> Unit {
  let b = self.bounds()
  self.rectangle((0.0, b.height), b.width, b.height)
  self.stroke()
}
