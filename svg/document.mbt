///|
// An SVG document ready to draw: its tree, stylesheet and sizing, as
// prawn-svg's `Document`; and what drawing needs from the host (fonts and
// files).

///|
/// A font the host can draw SVG text with.
pub(all) struct SvgFont {
  /// the font's index in the page model
  index : Int
  /// the advance of each UTF-16 code unit of a string at a size, kerning
  /// included (Prawn's `width_of`)
  advances : (String, Double) -> Array[Double]
  /// the font's height at a size: ascender, descender and line gap
  height : (Double) -> Double
}

///|
/// What an SVG is drawn with.
pub(all) struct Environment {
  /// the installed font families (Prawn's `font_families`), each with its
  /// styles: `normal`, `bold`, `italic`, `bold_italic`
  families : Array[(String, Array[String])]
  /// a family's font in a style, if the host can draw it
  load_font : (String, String) -> SvgFont?
  /// the family used when none the SVG names is installed
  fallback_font : String
  /// the bytes of a file an `<image>` names (a path relative to the SVG's
  /// directory, or absolute), if readable
  read_file : (String) -> Bytes?
  /// the font size the document is at where the SVG is drawn (what
  /// `dominant-baseline: middle` measures with, as prawn-svg does)
  ambient_font_size : Double
}

///|
/// A parsed SVG document.
pub struct SvgDocument {
  root : Element
  /// its size, recalculated by `Sizing::resize`
  sizing : Sizing
  /// problems found while drawing (prawn-svg's `warnings`)
  warnings : Array[String]
  priv styles : Map[Int, Array[(String, String)]]
  priv elements_by_id : Map[String, Node]
  priv gradients : Map[String, GradientElement]
  priv mut env : Environment?
  /// the work budget, shared with the SVG documents drawn inside this one
  priv mut limits : Limits
  /// how many SVG documents this one is drawn inside (0 at the top)
  priv mut nesting : Int
  /// how many elements are being processed, one inside the other
  priv mut depth : Int
  /// the elements being processed, innermost last (`Element` uids, shared
  /// by the copies `<use>` makes): a reference must not lead back to one
  priv active : Array[Int]
  /// the gradients being read (ids): an `href` must not lead back to one
  priv resolving : Array[String]
  /// the first element with each id, once `find_raw` needs it
  priv mut raw_ids : Map[String, Element]?
}

///|
/// What drawing an SVG may cost. Nothing in an SVG is unbounded on its
/// own (the tree is at most `max_xml_depth` deep, references never lead
/// back to an element being processed), but references multiply: ten
/// `<use>`s of a group of ten `<use>`s of ... draw 10^n elements. Every
/// element processed and every call copied (clip paths, markers) is paid
/// for from this budget, which is shared by the SVG images drawn inside
/// the document.
priv struct Limits {
  mut work : Int
}

///|
/// The work budget of a document and the SVG images in it. A drawing
/// that legitimately needs more is far beyond what prawn-svg can render.
let max_work : Int = 250_000

///|
/// The deepest elements may be processed one inside the other, counting
/// the elements each `<use>` brings in.
let max_depth : Int = 512

///|
/// The deepest SVG documents may be drawn inside each other (`<image>`s
/// of SVG documents).
let max_nesting : Int = 8

///|
/// Pay for `units` of work; false (with a warning, once) when the budget
/// is exhausted, and the work must not be done.
fn SvgDocument::spend(self : SvgDocument, units : Int) -> Bool {
  if self.limits.work > max_work {
    return false
  }
  self.limits.work += units
  if self.limits.work > max_work {
    self.warnings.push(
      "SVG is too complex to render in full; skipping the rest of it",
    )
    return false
  }
  true
}

///|
/// Add a warning unless it was already given.
fn SvgDocument::warn_once(self : SvgDocument, message : String) -> Unit {
  if !self.warnings.contains(message) {
    self.warnings.push(message)
  }
}

///|
/// Why an SVG cannot be read.
pub suberror SvgError {
  SvgError(String)
}

///|
/// Parse an SVG document to be drawn in `bounds` (width, height), at
/// `width` and/or `height` when given (prawn-svg's `Document.new` with its
/// `:width` and `:height` options).
pub fn SvgDocument::parse(
  text : String,
  bounds : (Double, Double),
  width? : Double,
  height? : Double,
  preserve_aspect_ratio? : String,
) -> SvgDocument raise SvgError {
  let root = parse_xml(text) catch {
    XmlError(message) => raise SvgError(message)
  }
  let sizing = Sizing::new(
    bounds,
    width?=root.attr("width"),
    height?=root.attr("height"),
    view_box?=root.attr("viewBox"),
    preserve_aspect_ratio?=match preserve_aspect_ratio {
      Some(p) => Some(p)
      None => root.attr("preserveAspectRatio")
    },
  )
  sizing.resize(width?, height?)
  let all = root.descendants()
  {
    root,
    sizing,
    warnings: [],
    styles: element_styles(root, all),
    elements_by_id: {},
    gradients: {},
    env: None,
    limits: { work: 0, },
    nesting: 0,
    depth: 0,
    active: [],
    resolving: [],
    raw_ids: None,
  }
}

///|
/// The first element of the tree whose `id` is `id` (prawn-svg's XPath
/// fallback for references to elements not processed yet).
fn SvgDocument::find_raw(self : SvgDocument, id : String) -> Element? {
  let ids = match self.raw_ids {
    Some(ids) => ids
    None => {
      // indexed once: a scan per reference is quadratic
      let ids : Map[String, Element] = Map([])
      for e in self.root.descendants() {
        if e.attr("id") is Some(i) && !ids.contains(i) {
          ids[i] = e
        }
      }
      self.raw_ids = Some(ids)
      ids
    }
  }
  ids.get(id)
}

///|
/// Draw the document at its sizing (prawn-svg's `Renderer#draw`): the ops
/// of a graphic whose origin is the image's top-left corner, clipped to
/// its size. Nothing, with a warning, when the sizing is invalid.
///
/// The image's top-left corner is at `origin` (points, y down) on a page
/// `page_height` tall, and `stack` is the transformation stack of the
/// Prawn document it is drawn into (see `TransformationStack`).
pub fn SvgDocument::render(
  self : SvgDocument,
  env : Environment,
  origin~ : (Double, Double),
  page_height~ : Double,
  stack~ : TransformationStack,
) -> Array[@pagelayout.GraphicOp] {
  self.limits.work = 0
  let calls = self.calls(env)
  let ops = []
  if calls is Some(calls) {
    let top = page_height - origin.1
    lower(calls, self, env, ops, stack, (origin.0, top), {
      a: 1,
      b: 0,
      c: 0,
      d: -1,
      e: origin.0,
      f: top,
    })
  }
  ops
}

///|
/// The drawing calls of the document, wrapped as `Renderer#draw` wraps
/// them (a state saved around a clip to the image's box); None when the
/// sizing is invalid.
fn SvgDocument::calls(self : SvgDocument, env : Environment) -> Array[Call]? {
  self.env = Some(env)
  let sizing = self.sizing
  if sizing.invalid {
    self.warnings.push(
      "Zero or negative sizing data means this SVG cannot be rendered",
    )
    return None
  }
  self.warnings.clear()
  self.elements_by_id.clear()
  self.gradients.clear()
  self.depth = 0
  self.active.clear()
  self.resolving.clear()
  let calls = []
  let root = Node::new(self, Root, Some(self.root), calls, State::new(sizing))
  root.process()
  Some([
    SaveState(
      [
        Rectangle(0, 0, sizing.output_width, sizing.output_height),
        Clip,
        ..calls,
      ],
    ),
  ])
}
