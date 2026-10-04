///|
// Prawn's transformations and transparency (`Prawn::Graphics::
// Transformation`, `Transparency`): a block whose content is drawn under a
// changed coordinate system or opacity. Like Prawn's `q … cm … Q`, what the
// block draws on the page is wrapped in one pagelayout graphic group.

///|
/// pagelayout's page space is y down from the top of a page `height` tall;
/// Prawn's is y up. `flip` maps one to the other (it is its own inverse).
fn flip(height : Double) -> @pagelayout.Matrix {
  { a: 1.0, b: 0.0, c: 0.0, d: -1.0, e: 0.0, f: height, }
}

///|
/// A page item as ops of a graphic group in page space; None for those
/// that draw nothing (links and anchors stay page items).
fn item_ops(item : @pagelayout.PageItem) -> Array[@pagelayout.GraphicOp]? {
  match item {
    Text(run) => Some([Text(run)])
    Image(image) => Some([Image(image)])
    // kept in a save and restore of its own, as pagelayout draws each graphic
    Graphic(g) if g.x_pt == 0.0 && g.y_pt == 0.0 =>
      Some([Save, ..g.ops, Restore])
    Graphic(g) =>
      Some(
        [
          Save,
          Transform({ ..@pagelayout.identity, e: g.x_pt, f: g.y_pt, }),
          ..g.ops,
          Restore,
        ],
      )
    Rect(r) =>
      Some([
        Path({
          segments: [Rectangle(r.x_pt, r.y_pt, r.w_pt, r.h_pt)],
          fill: r.fill.map(c => Solid(c)),
          fill_rule: NonZero,
          stroke: r.stroke.map(c => Solid(c)),
          stroke_style: {
            ..@pagelayout.StrokeStyle::default(),
            width: Width(r.stroke_w_pt),
          },
        }),
      ])
    Link(_) | Anchor(_) => None
  }
}

///|
/// `body`, with what it draws on the current page wrapped in a group that
/// starts with `setup` (a transform, an opacity) inside save and restore,
/// which also save and restore the graphics state (colours, line style).
/// What lands on other pages is drawn as it is: a new page starts without
/// the block's state, as in Prawn.
fn Document::group(
  self : Document,
  setup : Array[@pagelayout.GraphicOp],
  body : () -> Unit raise,
) -> Unit raise {
  // the page it starts on (its record holds it through insertions)
  let page = self.page()
  let start = page.items.length()
  // q: a copy of the graphics state goes on the page's stack; Q pops the
  // stack of the page current then (pdf-core's GraphicStateStack)
  page.stack.push(
    match page.stack.last() {
      Some(state) => state.copy()
      // none to copy (a stack restored past its bottom): pdf-core pushes
      // the defaults, one state
      None => GraphicState::new()
    },
  )
  let saved_ctm = page.ctm
  match setup {
    [Transform(m)] => page.ctm = saved_ctm.after(m)
    _ => ()
  }
  // the block's items wrapped in Save and Restore, whatever happens
  let finish = fn() {
    page.ctm = saved_ctm
    let items = page.items
    let ops : Array[@pagelayout.GraphicOp] = [Save, ..setup]
    let kept : Array[@pagelayout.PageItem] = []
    for item in items[start:] {
      match item_ops(item) {
        Some(more) => ops.append(more)
        None => kept.push(item)
      }
    }
    ops.push(Restore)
    items.truncate(start)
    items.push(Graphic({ x_pt: 0.0, y_pt: 0.0, ops, }))
    items.append(kept)
  }
  // an error in the block leaves it with the state it saved popped
  let mut restoring = false
  errdefer {
    if !restoring {
      self.page().stack.pop() |> ignore
    }
    finish()
  }
  body()
  // Q: the stack of the page current now; one with nothing left to
  // restore (a new page holds one state, so two blocks around a page break
  // empty it) is pdf-core's EmptyGraphicStateStack
  restoring = true
  let stack = self.page().stack
  if stack.is_empty() {
    raise EmptyGraphicStateStack
  }
  stack.pop() |> ignore
  finish()
}

///|
/// Prawn's `transformation_matrix` with a block: `body` drawn under the
/// matrix `[a, b, c, d, e, f]` in Prawn's page space (y up).
pub fn Document::transformation_matrix(
  self : Document,
  matrix : (Double, Double, Double, Double, Double, Double),
  body : () -> Unit raise,
) -> Unit raise {
  let (a, b, c, d, e, f) = matrix
  let f_ = flip(self.page_h())
  let m : @pagelayout.Matrix = { a, b, c, d, e, f, }
  self.group([Transform(f_.after(m.after(f_)))], body)
}

///|
/// Prawn's `translate` with a block.
pub fn Document::translate(
  self : Document,
  x : Double,
  y : Double,
  body : () -> Unit raise,
) -> Unit raise {
  self.transformation_matrix((1.0, 0.0, 0.0, 1.0, x, y), body)
}

///|
/// The origin `(x, y)` of the bounds on the page (Prawn's
/// `bounds.absolute_left/bottom` plus the point).
fn Document::absolute(
  self : Document,
  point : (Double, Double),
) -> (Double, Double) {
  let box = self.current_box()
  (box.left + point.0, box.top - box.height_at(self.y()) + point.1)
}

///|
/// Prawn's `rotate` with a block: `angle` degrees counterclockwise, about
/// the page's origin or `origin` (a point of the bounds).
pub fn Document::rotate(
  self : Document,
  angle : Double,
  origin? : (Double, Double),
  body : () -> Unit raise,
) -> Unit raise {
  let rad = angle * @math.PI / 180.0
  let cos = @math.cos(rad)
  let sin = @math.sin(rad)
  match origin {
    None => self.transformation_matrix((cos, sin, -sin, cos, 0.0, 0.0), body)
    Some(o) => {
      let (x, y) = self.absolute(o)
      let x_prime = x * cos - y * sin
      let y_prime = x * sin + y * cos
      self.translate(x - x_prime, y - y_prime, () => {
        self.transformation_matrix((cos, sin, -sin, cos, 0.0, 0.0), body)
      })
    }
  }
}

///|
/// Prawn's `scale` with a block, about the page's origin or `origin`.
pub fn Document::scale(
  self : Document,
  factor : Double,
  origin? : (Double, Double),
  body : () -> Unit raise,
) -> Unit raise {
  match origin {
    None =>
      self.transformation_matrix((factor, 0.0, 0.0, factor, 0.0, 0.0), body)
    Some(o) => {
      let (x, y) = self.absolute(o)
      self.translate(x - factor * x, y - factor * y, () => {
        self.transformation_matrix((factor, 0.0, 0.0, factor, 0.0, 0.0), body)
      })
    }
  }
}

///|
/// Prawn's `transparent`: `body` drawn with fill opacity `opacity` and
/// stroke opacity `stroke_opacity` (by default the same), each clamped to
/// 0 to 1.
pub fn Document::transparent(
  self : Document,
  opacity : Double,
  stroke_opacity? : Double,
  body : () -> Unit raise,
) -> Unit raise {
  let clamp = fn(x : Double) {
    if x < 0.0 {
      0.0
    } else if x > 1.0 {
      1.0
    } else {
      x
    }
  }
  let fill = clamp(opacity)
  let stroke = clamp(stroke_opacity.unwrap_or(opacity))
  self.group([Alpha(fill, stroke)], body)
}

///|
/// Prawn's `save_graphics_state` with a block: what the block changes in
/// the graphics state is undone after it.
pub fn Document::save_graphics_state(
  self : Document,
  body : () -> Unit raise,
) -> Unit raise {
  self.group([], body)
}

///|
fn is_identity(m : @pagelayout.Matrix) -> Bool {
  m == @pagelayout.identity
}

///|
/// The inverse of an affine matrix.
fn inverse(m : @pagelayout.Matrix) -> @pagelayout.Matrix {
  let det = m.a * m.d - m.b * m.c
  let a = m.d / det
  let b = -m.b / det
  let c = -m.c / det
  let d = m.a / det
  { a, b, c, d, e: -(a * m.e + c * m.f), f: -(b * m.e + d * m.f), }
}

///|
/// A path segment mapped by `m` (a rectangle becomes its four sides, in the
/// order pagelayout draws it, unless `m` is the identity).
fn map_segment(
  segment : @pagelayout.PathSegment,
  m : @pagelayout.Matrix,
) -> Array[@pagelayout.PathSegment] {
  if is_identity(m) {
    return [segment]
  }
  match segment {
    MoveTo(x, y) => {
      let (x, y) = m.apply(x, y)
      [MoveTo(x, y)]
    }
    LineTo(x, y) => {
      let (x, y) = m.apply(x, y)
      [LineTo(x, y)]
    }
    CurveTo(x1, y1, x2, y2, x3, y3) => {
      let (x1, y1) = m.apply(x1, y1)
      let (x2, y2) = m.apply(x2, y2)
      let (x3, y3) = m.apply(x3, y3)
      [CurveTo(x1, y1, x2, y2, x3, y3)]
    }
    Rectangle(x, y, w, h) => {
      // from the bottom left (x, y + h) counterclockwise on the page
      let (x0, y0) = m.apply(x, y + h)
      let (x1, y1) = m.apply(x + w, y + h)
      let (x2, y2) = m.apply(x + w, y)
      let (x3, y3) = m.apply(x, y)
      [MoveTo(x0, y0), LineTo(x1, y1), LineTo(x2, y2), LineTo(x3, y3), Close]
    }
    Close => [Close]
  }
}
