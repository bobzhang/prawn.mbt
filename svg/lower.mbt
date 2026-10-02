///|
// Running the calls as Prawn would, into pagelayout graphic ops: Prawn's
// graphics state (colours, line style, transformation) is tracked across
// saves and restores, a path is collected until it is painted or clipped
// to, and text is measured and placed as `Renderer#rewrite_call_arguments`
// and Prawn's `draw_text` place it.

///|
/// A paint; for a gradient, the pattern matrix Prawn gave it when it was
/// set (from pattern space to the page's default space).
priv struct SetPaint {
  rgb : Int
  gradient : (GradientArgs, @pagelayout.Matrix)?
}

///|
priv struct GState {
  mut fill : SetPaint
  mut stroke : SetPaint
  mut width : Double
  mut cap : @pagelayout.LineCap
  mut join : @pagelayout.LineJoin
  mut dash : Array[Double]
  mut ctm : @pagelayout.Matrix
}

///|
fn GState::copy(self : GState) -> GState {
  { ..self, }
}

///|
priv struct Lowering {
  doc : SvgDocument
  env : Environment
  ops : Array[@pagelayout.GraphicOp]
  mut state : GState
  stack : Array[GState]
  /// the path being built: segments, each with the transformation it was
  /// given under
  path : Array[(@pagelayout.PathSegment, @pagelayout.Matrix)]
  mut font : (String, String)?
  mut spacing : Double
  mut mode : String
  mut cursor : (Double, Double)
  /// Prawn's transformation stack for the document drawn into
  prawn : TransformationStack
  /// the absolute top-left corner (PDF user space, y up) of the box
  /// Prawn draws in, which its transformations are anchored at
  anchor : (Double, Double)
  /// the page placement of the graphic's space (y down from the image's
  /// top-left corner, to PDF user space)
  origin : @pagelayout.Matrix
}

///|
fn lower(
  calls : Array[Call],
  doc : SvgDocument,
  env : Environment,
  ops : Array[@pagelayout.GraphicOp],
  prawn : TransformationStack,
  anchor : (Double, Double),
  origin : @pagelayout.Matrix,
  ctm? : @pagelayout.Matrix = @pagelayout.identity,
) -> Unit {
  let black = SetPaint::{ rgb: 0, gradient: None, }
  let l = Lowering::{
    prawn,
    anchor,
    origin,
    doc,
    env,
    ops,
    state: {
      fill: black,
      stroke: black,
      width: 1,
      cap: ButtCap,
      join: MiterJoin,
      dash: [],
      ctm,
    },
    stack: [],
    path: [],
    font: None,
    spacing: 0,
    mode: "fill",
    cursor: (0, 0),
  }
  l.run(calls)
}

///|
fn Lowering::save(self : Lowering) -> Unit {
  self.ops.push(Save)
  self.stack.push(self.state.copy())
}

///|
fn Lowering::restore(self : Lowering) -> Unit {
  match self.stack.pop() {
    Some(state) => {
      self.ops.push(Restore)
      self.state = state
    }
    None => ()
  }
}

///|
fn Lowering::transform(self : Lowering, m : @pagelayout.Matrix) -> Unit {
  self.ops.push(Transform(m))
  self.state.ctm = self.state.ctm.after(m)
}

///|
fn Lowering::segment(self : Lowering, s : @pagelayout.PathSegment) -> Unit {
  self.path.push((s, self.state.ctm))
}

///|
/// The collected path in the current space, and a fresh one begun.
fn Lowering::take_path(self : Lowering) -> Array[@pagelayout.PathSegment] {
  let ctm = self.state.ctm
  let out = []
  for entry in self.path {
    let (segment, at) = entry
    if at == ctm {
      out.push(segment)
      continue
    }
    // given under another transformation: map it into this one
    let m = match invert(ctm) {
      Some(inverse) => inverse.after(at)
      None => @pagelayout.identity
    }
    let p = fn(x : Double, y : Double) { m.apply(x, y) }
    match segment {
      MoveTo(x, y) => {
        let (a, b) = p(x, y)
        out.push(MoveTo(a, b))
      }
      LineTo(x, y) => {
        let (a, b) = p(x, y)
        out.push(LineTo(a, b))
      }
      CurveTo(x1, y1, x2, y2, x, y) => {
        let (a1, b1) = p(x1, y1)
        let (a2, b2) = p(x2, y2)
        let (a, b) = p(x, y)
        out.push(CurveTo(a1, b1, a2, b2, a, b))
      }
      Rectangle(x, y, w, h) => {
        let (a, b) = p(x, y + h)
        out.push(MoveTo(a, b))
        let (a, b) = p(x + w, y + h)
        out.push(LineTo(a, b))
        let (a, b) = p(x + w, y)
        out.push(LineTo(a, b))
        let (a, b) = p(x, y)
        out.push(LineTo(a, b))
        out.push(Close)
      }
      Close => out.push(Close)
    }
  }
  self.path.clear()
  out
}

///|
/// A paint as the current space sees it.
fn Lowering::paint(self : Lowering, set : SetPaint) -> @pagelayout.Paint {
  match set.gradient {
    None => Solid(color_of(set.rgb))
    Some((g, pattern)) => {
      // Prawn's pattern space is y-up, `from` at its origin; the pattern
      // matrix, relative to the current space
      let relative = match invert(self.origin.after(self.state.ctm)) {
        Some(inverse) => inverse.after(pattern)
        None => pattern
      }
      let stops = g.stops.map(s => @pagelayout.GradientStop::{
        offset: s.0,
        color: color_of(s.1),
      })
      let x2 = g.to.0 - g.from.0
      let y2 = -(g.to.1 - g.from.1)
      GradientPaint({
        shape: if g.radial {
          Radial(x1=0, y1=0, r1=g.r1, x2~, y2~, r2=g.r2)
        } else {
          Linear(x1=0, y1=0, x2~, y2~)
        },
        stops,
        transform: relative,
      })
    }
  }
}

///|
/// Prawn's stroke style in effect, `width` wide: a line width of 0 (or
/// less) is written as `0 w`, which PDF draws as the thinnest line the
/// device can, a hairline.
fn Lowering::stroke_style(
  self : Lowering,
  width? : Double = self.state.width,
) -> @pagelayout.StrokeStyle {
  {
    width: if width > 0.0 {
      Width(width)
    } else {
      Hairline
    },
    cap: self.state.cap,
    join: self.state.join,
    miter_limit: 10,
    dash: self.state.dash,
    dash_phase: 0,
  }
}

///|
/// The pattern matrix Prawn gives a gradient set now: the transformation
/// stack's product, a translation to the gradient's start (absolute), then
/// the gradient transform (flipped, not anchored: prawn-svg's
/// `AdditionalGradientTransforms`).
fn Lowering::pattern_matrix(
  self : Lowering,
  g : GradientArgs,
) -> @pagelayout.Matrix {
  let (left, top) = self.anchor
  let from = (left + g.from.0, top - g.from.1)
  let t = g.transform
  let flipped : @pagelayout.Matrix = {
    a: t.a,
    b: -t.b,
    c: -t.c,
    d: t.d,
    e: t.e,
    f: -t.f,
  }
  self.prawn.product().after(translate(from.0, from.1)).after(flipped)
}

///|
/// Prawn's `rounded_polygon` corner (`rounded_vertex`).
fn point_on_line(
  distance : Double,
  p0 : (Double, Double),
  p1 : (Double, Double),
) -> (Double, Double) {
  let length = ((p1.0 - p0.0) * (p1.0 - p0.0) + (p1.1 - p0.1) * (p1.1 - p0.1)).sqrt()
  let p = (length - distance) / length
  (p0.0 + p * (p1.0 - p0.0), p0.1 + p * (p1.1 - p0.1))
}

///|
let kappa : Double = 4.0 * ((2.0 : Double).sqrt() - 1.0) / 3.0

///|
/// What ends a call with a block once its children have run.
priv enum Epilogue {
  NoEpilogue
  /// restore both graphics states (a transformation or transparency block)
  RestoreBoth
  /// restore the graphics state only (Prawn's `save_graphics_state` block)
  RestoreState
  /// paint the path the children built
  PaintPath(PaintKind, Bool)
  /// restore the character spacing
  RestoreSpacing(Double)
  /// restore the text rendering mode
  RestoreMode(String)
}

///|
priv struct Frame {
  calls : Array[Call]
  mut next : Int
  epilogue : Epilogue
}

///|
/// Run the calls. Blocks nest as deep as the SVG's elements (and the
/// elements `<use>` brings in) do, so they are run from an explicit stack
/// rather than by recursion.
fn Lowering::run(self : Lowering, calls : Array[Call]) -> Unit {
  let frames = [Frame::{ calls, next: 0, epilogue: NoEpilogue, }]
  while frames.last() is Some(frame) {
    if frame.next < frame.calls.length() {
      let call = frame.calls[frame.next]
      frame.next += 1
      match self.call(call) {
        Some((children, epilogue)) =>
          frames.push({ calls: children, next: 0, epilogue, })
        None => ()
      }
    } else {
      ignore(frames.pop())
      self.finish(frame.epilogue)
    }
  }
}

///|
/// Run a call; for a call with a block, start it and return its children
/// and what ends it.
fn Lowering::call(self : Lowering, call : Call) -> (Array[Call], Epilogue)? {
  match call {
    Transform(m, None) => {
      self.prawn.add(anchored(m, self.anchor.0, self.anchor.1))
      self.transform(m)
    }
    Transform(m, Some(children)) => {
      self.prawn.save()
      self.save()
      self.prawn.add(anchored(m, self.anchor.0, self.anchor.1))
      self.transform(m)
      return Some((children, RestoreBoth))
    }
    Transparent(fill, stroke, children) => {
      self.prawn.save()
      self.save()
      self.ops.push(Alpha(fill, stroke))
      return Some((children, RestoreBoth))
    }
    SaveState(children) => {
      // the block form: Prawn never pops the level it pushed
      self.prawn.save()
      self.save()
      return Some((children, RestoreState))
    }
    Save => {
      self.prawn.save()
      self.save()
    }
    Restore => {
      self.prawn.restore()
      self.restore()
    }
    Paint(kind, even_odd, children) =>
      return Some((children, PaintPath(kind, even_odd)))
    FillColor(rgb) => self.state.fill = { rgb, gradient: None, }
    StrokeColor(rgb) => self.state.stroke = { rgb, gradient: None, }
    FillGradient(g) =>
      self.state.fill = {
        rgb: g.stops[0].1,
        gradient: Some((g, self.pattern_matrix(g))),
      }
    StrokeGradient(g) =>
      self.state.stroke = {
        rgb: g.stops[0].1,
        gradient: Some((g, self.pattern_matrix(g))),
      }
    LineWidth(w) => self.state.width = w
    CapStyle(c) => self.state.cap = c
    JoinStyle(j) => self.state.join = j
    Dash(d) => self.state.dash = d
    Undash => self.state.dash = []
    MoveTo(x, y) => self.segment(MoveTo(x, y))
    LineTo(x, y) => self.segment(LineTo(x, y))
    CurveTo(x1, y1, x2, y2, x, y) => self.segment(CurveTo(x1, y1, x2, y2, x, y))
    ClosePath => self.segment(Close)
    Rectangle(x, y, w, h) => self.segment(Rectangle(x, y, w, h))
    RoundedRectangle(x, y, w, h, r) => {
      // Prawn's `rounded_polygon` over the corners, in y-down terms
      let points = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
      let (sx, sy) = point_on_line(r, points[1], points[0])
      self.segment(MoveTo(sx, sy))
      let ring = [..points, points[0], points[1]]
      for i in 0..<4 {
        let p0 = ring[i]
        let p1 = ring[i + 1]
        let p2 = ring[i + 2]
        let radial1 = point_on_line(r, p0, p1)
        let bezier1 = point_on_line(r - r * kappa, p0, p1)
        let radial2 = point_on_line(r, p2, p1)
        let bezier2 = point_on_line(r - r * kappa, p2, p1)
        self.segment(LineTo(radial1.0, radial1.1))
        self.segment(
          CurveTo(
            bezier1.0,
            bezier1.1,
            bezier2.0,
            bezier2.1,
            radial2.0,
            radial2.1,
          ),
        )
      }
      self.segment(Close)
    }
    Ellipse(x, y, r1, r2) => {
      // Prawn's `ellipse`, its quarters in y-up order
      let l1 = r1 * kappa
      let l2 = r2 * kappa
      self.segment(MoveTo(x + r1, y))
      self.segment(CurveTo(x + r1, y - l2, x + l1, y - r2, x, y - r2))
      self.segment(CurveTo(x - l1, y - r2, x - r1, y - l2, x - r1, y))
      self.segment(CurveTo(x - r1, y + l2, x - l1, y + r2, x, y + r2))
      self.segment(CurveTo(x + l1, y + r2, x + r1, y + l2, x + r1, y))
      self.segment(MoveTo(x, y))
    }
    Clip => {
      let segments = self.take_path()
      self.ops.push(Clip(segments, NonZero))
    }
    TextGroup(children) => {
      self.cursor = (0, 0)
      return Some((children, NoEpilogue))
    }
    CharacterSpacing(v, children) => {
      let saved = self.spacing
      self.spacing = v
      return Some((children, RestoreSpacing(saved)))
    }
    TextRenderingMode(m, children) => {
      let saved = self.mode
      self.mode = m
      return Some((children, RestoreMode(saved)))
    }
    Noop(children) => return Some((children, NoEpilogue))
    Font(family, subfamily) => self.font = Some((family, subfamily))
    DrawText(text, options) => self.draw_text(text, options)
    Image(data, mime, x, y, w, h) =>
      self.ops.push(Image({ x_pt: x, y_pt: y, w_pt: w, h_pt: h, data, mime, }))
    SubDocument(document) => {
      document.env = Some(self.env)
      // the translation before it is Prawn's `translate` to a point given
      // from the outer box's bottom edge, not a flipped one
      self.prawn.add(translate(0, self.doc.sizing.output_height))
      match document.calls(self.env) {
        // Prawn draws it in a box at the outer box's bottom-left corner,
        // which the transformation before it moves into place
        Some(calls) =>
          lower(
            calls,
            document,
            self.env,
            self.ops,
            self.prawn,
            (self.anchor.0, self.anchor.1 - self.doc.sizing.output_height),
            self.origin,
            ctm=self.state.ctm,
          )
        None => ()
      }
      self.doc.warnings.append(document.warnings)
    }
  }
  None
}

///|
/// End a call with a block, its children run.
fn Lowering::finish(self : Lowering, epilogue : Epilogue) -> Unit {
  match epilogue {
    NoEpilogue => ()
    RestoreBoth => {
      self.restore()
      self.prawn.restore()
    }
    RestoreState => self.restore()
    RestoreSpacing(saved) => self.spacing = saved
    RestoreMode(saved) => self.mode = saved
    PaintPath(kind, even_odd) => {
      let segments = self.take_path()
      if segments.is_empty() {
        return
      }
      let fill = match kind {
        FillOnly | FillAndStroke => Some(self.paint(self.state.fill))
        _ => None
      }
      let stroke = match kind {
        StrokeOnly | FillAndStroke => Some(self.paint(self.state.stroke))
        _ => None
      }
      if fill is None && stroke is None {
        return
      }
      self.ops.push(
        Path({
          segments,
          fill,
          fill_rule: if even_odd {
            EvenOdd
          } else {
            NonZero
          },
          stroke,
          stroke_style: self.stroke_style(),
        }),
      )
    }
  }
}

///|
/// The font text is drawn in: the last one set, else the fallback.
fn Lowering::current_font(self : Lowering) -> SvgFont? {
  match self.font {
    Some((family, subfamily)) =>
      match (self.env.load_font)(family, subfamily) {
        Some(font) => Some(font)
        None => (self.env.load_font)(self.env.fallback_font, "normal")
      }
    None => (self.env.load_font)(self.env.fallback_font, "normal")
  }
}

///|
/// `draw_text` as prawn-svg rewrites it: relative positions from the
/// cursor, the baseline and anchor adjusted, the cursor moved past.
fn Lowering::draw_text(self : Lowering, text : String, o : TextOptions) -> Unit {
  guard self.current_font() is Some(font) else { return }
  let mut x = o.x.unwrap_or(self.cursor.0)
  let mut y = o.y.unwrap_or(self.cursor.1)
  if o.dominant_baseline == Some("middle") {
    y += (font.height)(self.env.ambient_font_size) / 2.0
    self.cursor = (x, y)
  }
  x += o.dx
  y += o.dy
  let advances = (font.advances)(text, o.size)
  let count = text.length()
  // Prawn's width_of: the glyphs, and the character spacing after each
  let mut width = 0.0
  for a in advances {
    width += a
  }
  let chars = text.iter().count()
  width += self.spacing * chars.to_double()
  let mut spacing = self.spacing
  let mut stretch : Double? = None
  match o.stretch_to_width {
    Some(target) => {
      stretch = Some(target / width)
      width = target
    }
    None => ()
  }
  match o.pad_to_width {
    Some(target) => {
      spacing += (target - width) / chars.to_double()
      width = target
    }
    None => ()
  }
  match o.anchor {
    "middle" => {
      x -= width / 2.0
      self.cursor = (x + width / 2.0, y)
    }
    "end" => {
      x -= width
      self.cursor = (x, y)
    }
    _ => self.cursor = (x + width, y)
  }
  let color = match self.state.fill.gradient {
    None => color_of(self.state.fill.rgb)
    Some((g, _)) => color_of(g.stops[0].1)
  }
  if o.decoration == Some("underline") {
    // a `save_graphics_state` block
    self.prawn.save()
    self.save()
    self.ops.push(
      Path({
        segments: [MoveTo(x, y + 1.25), LineTo(x + width, y + 1.25)],
        fill: None,
        fill_rule: NonZero,
        stroke: Some(self.paint(self.state.stroke)),
        stroke_style: self.stroke_style(width=1),
      }),
    )
    self.restore()
  }
  // the advances with the character spacing after each character (its
  // last code unit, for a surrogate pair)
  let spaced = advances.copy()
  if spacing != 0.0 {
    for i in 0..<count {
      let unit = text[i].to_int()
      if !(unit >= 0xD800 && unit <= 0xDBFF) {
        spaced[i] += spacing
      }
    }
  }
  let transformed = o.rotate is Some(_) || stretch is Some(_)
  if transformed {
    self.save()
    self.transform(translate(x, y))
    match o.rotate {
      Some(r) => self.transform(rotation(r))
      None => ()
    }
    match stretch {
      Some(s) => self.transform(scale(s, 1.0))
      None => ()
    }
  }
  let run = @pagelayout.GlyphRun::{
    font: font.index,
    size_pt: o.size,
    x_pt: if transformed {
      0.0
    } else {
      x
    },
    baseline_pt: if transformed {
      0.0
    } else {
      y
    },
    text,
    advances_pt: spaced,
    color,
  }
  // the text rendering mode, the stroke in the stroke colour and the
  // stroke style in effect (Prawn outlines glyphs with the graphics
  // state's line width, cap, join and dash)
  let stroke = match self.state.stroke.gradient {
    None => color_of(self.state.stroke.rgb)
    Some((g, _)) => color_of(g.stops[0].1)
  }
  let stroke_style = self.stroke_style()
  self.ops.push(
    match self.mode {
      "fill" => Text(run)
      "stroke" =>
        PaintedText(run, { fill: false, stroke: Some(stroke), stroke_style, })
      "fill_stroke" =>
        PaintedText(run, { fill: true, stroke: Some(stroke), stroke_style, })
      _ => PaintedText(run, { fill: false, stroke: None, stroke_style, })
    },
  )
  if transformed {
    self.restore()
  }
}
