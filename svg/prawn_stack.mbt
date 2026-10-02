///|
// Prawn's transformation stack, which only gradients consult: a pattern's
// matrix is the product of the stack's top level (then a translation to the
// gradient's start). Prawn pushes a level on every `save_graphics_state`
// but, in its block form, never pops it, so levels leak: what a draw adds
// at the top of its own block stays in the level the next draw builds on.
// Gradients drawn after other SVG images in a document are placed by their
// transformations too, and this reproduces that.

///|
/// A document's Prawn transformation stack (see the module comment); one
/// per Prawn document, kept across the SVG images drawn into it.
pub struct TransformationStack {
  priv levels : Array[Array[@pagelayout.Matrix]]
}

///|
pub fn TransformationStack::new() -> TransformationStack {
  { levels: [[]], }
}

///|
fn TransformationStack::top(
  self : TransformationStack,
) -> Array[@pagelayout.Matrix] {
  match self.levels.last() {
    Some(level) => level
    None => {
      let level = []
      self.levels.push(level)
      level
    }
  }
}

///|
fn TransformationStack::save(self : TransformationStack) -> Unit {
  self.levels.push(self.top().copy())
}

///|
fn TransformationStack::restore(self : TransformationStack) -> Unit {
  ignore(self.levels.pop())
}

///|
fn TransformationStack::add(
  self : TransformationStack,
  m : @pagelayout.Matrix,
) -> Unit {
  self.top().push(m)
}

///|
/// The product of the top level's matrices, in order.
fn TransformationStack::product(
  self : TransformationStack,
) -> @pagelayout.Matrix {
  let mut m = @pagelayout.identity
  for t in self.top() {
    m = m.after(t)
  }
  m
}

///|
/// `m` (y-down, about the box's top-left) as Prawn writes it: flipped to
/// y-up and anchored at the box's absolute top-left `(left, top)`
/// (`Renderer#rewrite_call_arguments` for `transformation_matrix`).
fn anchored(
  m : @pagelayout.Matrix,
  left : Double,
  top : Double,
) -> @pagelayout.Matrix {
  let flipped : @pagelayout.Matrix = {
    a: m.a,
    b: -m.b,
    c: -m.c,
    d: m.d,
    e: m.e,
    f: -m.f,
  }
  translate(left, top).after(flipped).after(translate(-left, -top))
}
