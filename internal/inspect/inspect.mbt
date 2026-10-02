///|
/// What a page shows, in the terms the comparison judges (PLAN.md §3): its
/// size, every glyph and every mark (path, image, shading), each with its
/// place in the page's paint order.
pub(all) struct PageView {
  width : Double
  height : Double
  rotate : Int
  glyphs : Array[Glyph]
  marks : Array[Mark]
}

///|
/// A colour as painted: its colour space, components and constant alpha.
pub(all) struct Paint {
  space : String
  values : Array[Double]
  alpha : Double
}

///|
/// An axis-aligned rectangle in page space.
pub(all) struct Rect {
  x0 : Double
  y0 : Double
  x1 : Double
  y1 : Double
}

///|
/// One shown glyph. `x`/`y` is its baseline origin in page space (PDF
/// points, y up); `size` the font size it was shown at (`Tf`); `matrix` the
/// linear part `[a, b, c, d]` of its render matrix (size, horizontal
/// scaling and rotation in page space). `fill` and `stroke` are the paints
/// its render mode uses.
pub(all) struct Glyph {
  text : String
  font : String
  size : Double
  matrix : Array[Double]
  x : Double
  y : Double
  mode : Int
  fill : Paint?
  stroke : Paint?
  /// Its stroke's pen (see `pen`), empty when it is not stroked.
  pen : Array[Double]
  /// Exact facts about how it is painted: its stroke's cap, join, miter
  /// limit and dashes, and the soft mask in effect.
  style : Json
  clip : Rect?
  blend : String
  /// Where it is drawn (its font's ascent to descent, its advance), for
  /// paint-order checks; not compared itself.
  extent : Rect
  /// Its position in the page's paint order (glyphs and marks together).
  order : Int
}

///|
/// A non-text mark: `kind` is "path", "image", "inline-image" or "shading".
/// `points` are its geometry in page space (a path's segment points, an
/// image's corners); `lengths` its stroke's line width and dash in page
/// units; `paints` its stroke and fill; `exact` the properties that must
/// match exactly (segment kinds and closure, winding rule, line cap and
/// join, an image's dictionary and data hash, …).
pub(all) struct Mark {
  kind : String
  points : Array[Double]
  lengths : Array[Double]
  paints : Array[Paint]
  exact : Json
  clip : Rect?
  blend : String
  extent : Rect
  order : Int
}

///|
fn pdf_name(text : String) -> @core.PdfName {
  let bytes = Array::make(text.length(), b'\x00')
  for i in 0..<text.length() {
    bytes[i] = text[i].to_int().to_byte()
  }
  @core.pdf_name_of_bytes(Bytes::from_array(bytes))
}

///|
fn name_text(n : @core.PdfName) -> String {
  let sb = StringBuilder()
  for b in n.bytes() {
    sb.write_char(b.to_int().unsafe_to_char())
  }
  let text = sb.to_string()
  if text.has_prefix("/") {
    text[1:].to_owned()
  } else {
    text
  }
}

///|
/// A font's PostScript name without a subset tag (`ABCDEF+`).
fn font_name(font : @pdflite.PdfFont) -> String {
  let name = match font {
    PdfFontStandard(data) => data.font.name()
    PdfFontSimple({ basefont: Some(n), .. }) => name_text(n)
    PdfFontSimple(simple) => simple.debug_name()
    PdfFontCIDKeyed(cid) => name_text(cid.basefont)
  }
  match name.find("+") {
    Some(6) => name[7:].to_owned()
    _ => name
  }
}

///|
fn space_name(space : @pdflite.PdfColourSpace) -> String {
  match space {
    PdfDeviceGray => "DeviceGray"
    PdfDeviceRGB => "DeviceRGB"
    PdfDeviceCMYK => "DeviceCMYK"
    PdfCalGray(_) => "CalGray"
    PdfCalRGB(_) => "CalRGB"
    PdfLab(_) => "Lab"
    PdfICCBased(n, alternate, _, _, _) =>
      "ICCBased(\{n}, \{space_name(alternate)})"
    PdfIndexed(base, _) => "Indexed(\{space_name(base)})"
    PdfPattern | PdfPatternWithBaseColourSpace(_) => "Pattern"
    PdfSeparation(n, _, _) => "Separation(\{name_text(n)})"
    PdfDeviceN(_) => "DeviceN"
  }
}

///|
fn colour_values(values : @pdflite.PdfContentColourValues) -> Array[Double] {
  match values {
    PdfContentColourFloats(xs) => xs
    PdfContentColourNamed(_, xs) => xs
    PdfContentColourPattern => []
  }
}

///|
fn fill_paint(state : @pdflite.PdfContentOperatorState) -> Paint {
  {
    space: space_name(state.path_state.colourspace_non_stroke),
    values: colour_values(state.path_state.colour_non_stroke),
    alpha: state.alpha_constant_non_stroke,
  }
}

///|
fn stroke_paint(state : @pdflite.PdfContentOperatorState) -> Paint {
  {
    space: space_name(state.path_state.colourspace_stroke),
    values: colour_values(state.path_state.colour_stroke),
    alpha: state.alpha_constant_stroke,
  }
}

///|
fn blend_name(doc : @pdflite.PdfDocument, mode : @syntax.PdfObject) -> String {
  match mode {
    PdfNameObject(n) => name_text(n)
    PdfArray(items) if items.length() > 0 => blend_name(doc, items[0])
    PdfIndirect(n) => blend_name(doc, doc.lookup_object_or_null(n))
    _ => "Normal"
  }
}

///|
/// How far `m` stretches lengths, on average over directions.
fn scale_of(m : @geometry.TransformMatrix) -> Double {
  (m.a * m.d - m.b * m.c).abs().sqrt()
}

///|
fn bounds_of(points : Array[Double]) -> Rect {
  let mut x0 = @double.infinity
  let mut y0 = @double.infinity
  let mut x1 = @double.neg_infinity
  let mut y1 = @double.neg_infinity
  let mut i = 0
  while i + 1 < points.length() {
    let x = points[i]
    let y = points[i + 1]
    if x < x0 {
      x0 = x
    }
    if x > x1 {
      x1 = x
    }
    if y < y0 {
      y0 = y
    }
    if y > y1 {
      y1 = y
    }
    i = i + 2
  }
  { x0, y0, x1, y1, }
}

///|
fn corners(
  m : @geometry.TransformMatrix,
  r : @geometry.PdfRectangle,
) -> Array[Double] {
  let out : Array[Double] = []
  for
    p in [
      (r.min_x, r.min_y),
      (r.max_x, r.min_y),
      (r.max_x, r.max_y),
      (r.min_x, r.max_y),
    ] {
    let q = m.apply(@geometry.point2(p.0, p.1))
    out.push(q.x)
    out.push(q.y)
  }
  out
}

///|
fn intersect(a : Rect?, b : Rect) -> Rect {
  match a {
    None => b
    Some(a) =>
      {
        x0: if a.x0 > b.x0 {
          a.x0
        } else {
          b.x0
        },
        y0: if a.y0 > b.y0 {
          a.y0
        } else {
          b.y0
        },
        x1: if a.x1 < b.x1 {
          a.x1
        } else {
          b.x1
        },
        y1: if a.y1 < b.y1 {
          a.y1
        } else {
          b.y1
        },
      }
  }
}

///|
/// FNV-1a, 64-bit, as a hex string: enough to tell data apart.
fn fnv(data : Bytes) -> String {
  let mut h = 0xcbf29ce484222325UL
  for b in data {
    h = (h ^ b.to_uint64()) * 0x100000001b3UL
  }
  let hex = "0123456789abcdef"
  let sb = StringBuilder()
  for i = 60; i >= 0; i = i - 4 {
    sb.write_char(hex[((h >> i) & 0xfUL).to_int()].unsafe_to_char())
  }
  sb.to_string()
}

///|
/// A PDF object as JSON: references followed (to a depth limit), streams as
/// their dictionary plus a hash of their (decoded) data.
fn object_json(
  doc : @pdflite.PdfDocument,
  obj : @syntax.PdfObject,
  depth? : Int = 0,
) -> Json {
  if depth > 8 {
    return "…"
  }
  match obj {
    PdfIndirect(n) =>
      object_json(doc, doc.lookup_object_or_null(n), depth=depth + 1)
    PdfNameObject(n) => ("/" + name_text(n)).to_json()
    PdfArray(items) =>
      Json::array(items.map(x => object_json(doc, x, depth=depth + 1)))
    PdfDictionary(entries) => {
      let out : Map[String, Json] = Map([])
      for entry in entries {
        out[name_text(entry.0)] = object_json(doc, entry.1, depth=depth + 1)
      }
      Json::object(out)
    }
    PdfStreamObject(stream) => {
      let out : Map[String, Json] = Map([])
      match stream.dictionary {
        PdfDictionary(entries) =>
          for entry in entries {
            let key = name_text(entry.0)
            // how the data is stored, not what it is
            if key != "Length" && key != "Filter" && key != "DecodeParms" {
              out[key] = object_json(doc, entry.1, depth=depth + 1)
            }
          }
        _ => ()
      }
      let data = obj.stream_bytes() catch { _ => b"" }
      out["data"] = fnv(data).to_json()
      Json::object(out)
    }
    _ => ToJson::to_json(obj)
  }
}

///|
/// What a page's content shows, collected while walking its operators.
priv struct Walk {
  doc : @pdflite.PdfDocument
  glyphs : Array[Glyph]
  marks : Array[Mark]
  mut order : Int
  /// The clip in effect (page space; `None` is the whole page), with the
  /// clips saved by `q`.
  mut clip : Rect?
  clips : Array[Rect?]
}

///|
fn Walk::next_order(self : Walk) -> Int {
  self.order = self.order + 1
  self.order
}

///|
/// The render matrix of a glyph shown with text matrix `tm`.
fn render_matrix(
  state : @pdflite.PdfContentOperatorState,
  tm : @geometry.TransformMatrix,
) -> @geometry.TransformMatrix {
  let ts = state.text_state
  @geometry.transform_matrix_compose(
    state.ctm,
    @geometry.transform_matrix_compose(tm, {
      a: ts.font_size * ts.horizontal_scaling,
      b: 0.0,
      c: 0.0,
      d: ts.font_size,
      e: 0.0,
      f: ts.rise,
    }),
  )
}

///|
fn Walk::show(
  self : Walk,
  state : @pdflite.PdfContentOperatorState,
  op : @content.PdfContentOp,
) -> Unit raise {
  let ts = state.text_state
  let font = ts.current_font
  // ' and " move to the next line themselves
  let placed = ts.content_apply_text_op(font, state.ctm, op)
  let name = font_name(font)
  let mode = ts.rendering_mode
  let fills = mode == 0 || mode == 2 || mode == 4 || mode == 6
  let strokes = mode == 1 || mode == 2 || mode == 5 || mode == 6
  let style : Map[String, Json] = Map([])
  let pen = if strokes {
    let (lengths, exact, _) = pen(state, state.ctm)
    for k, v in exact {
      style[k] = v
    }
    lengths
  } else {
    []
  }
  match soft_mask(self.doc, state) {
    Some(mask) => style["soft_mask"] = mask
    None => ()
  }
  let style = Json::object(style)
  let blend = blend_name(self.doc, state.blend_mode)
  for glyph in placed.glyphs {
    let m = render_matrix(state, glyph.text_matrix)
    let codepoints = font
      .text_extractor()
      .codepoints_of_text(font.content_bytes_of_charcode(glyph.charcode))
    let text = StringBuilder()
    for cp in codepoints {
      text.write_char(cp.unsafe_to_char())
    }
    let b = glyph.bounding_box
    self.glyphs.push({
      text: text.to_string(),
      font: name,
      size: ts.font_size,
      matrix: [m.a, m.b, m.c, m.d],
      x: m.e,
      y: m.f,
      mode,
      fill: if fills {
        Some(fill_paint(state))
      } else {
        None
      },
      stroke: if strokes {
        Some(stroke_paint(state))
      } else {
        None
      },
      pen,
      style,
      clip: self.clip,
      blend,
      extent: bounds_of([b.x0, b.y0, b.x1, b.y1, b.x2, b.y2, b.x3, b.y3]),
      order: self.next_order(),
    })
  }
}

///|
/// A path's points in page space, with an explicit final segment back to
/// the start of a closed subpath dropped (`re` and `m l l l l h` describe
/// the same rectangle), and the exact facts about it.
fn path_geometry(
  drawn : @shape.PdfDrawnPath,
  ctm : @geometry.TransformMatrix,
) -> (Array[Double], Map[String, Json]) {
  let points : Array[Double] = []
  let subpaths : Array[Json] = []
  let push = fn(p : @geometry.Point2) {
    let q = ctm.apply(p)
    points.push(q.x)
    points.push(q.y)
  }
  for sub in drawn.path.subpaths {
    if sub.segments.is_empty() {
      continue
    }
    // a fill closes every subpath itself: only a stroke tells open from
    // closed
    let closed = sub.closure is PdfPathClosed || !drawn.stroked
    let segments = sub.segments.copy()
    if closed && segments.length() > 1 {
      let start = match segments[0] {
        PdfPathStraight(p, _) | PdfPathBezier(p, _, _, _) => p
      }
      match segments[segments.length() - 1] {
        PdfPathStraight(_, q) if q.x == start.x && q.y == start.y =>
          segments.pop() |> ignore
        _ => ()
      }
    }
    let kinds = StringBuilder()
    for i, s in segments {
      match s {
        PdfPathStraight(p, q) => {
          if i == 0 {
            push(p)
          }
          push(q)
          kinds.write_char('l')
        }
        PdfPathBezier(p, c1, c2, q) => {
          if i == 0 {
            push(p)
          }
          push(c1)
          push(c2)
          push(q)
          kinds.write_char('c')
        }
      }
    }
    if closed {
      kinds.write_char('h')
    }
    subpaths.push(kinds.to_string().to_json())
  }
  let exact : Map[String, Json] = Map([])
  exact["subpaths"] = Json::array(subpaths)
  exact["stroked"] = drawn.stroked.to_json()
  exact["filled"] = drawn.filled.to_json()
  if drawn.filled {
    exact["even_odd"] = (drawn.path.winding_rule is PdfPathEvenOdd).to_json()
  }
  (points, exact)
}

///|
/// A stroke's pen under `ctm`: its lengths (the pen's shape in page space,
/// then the dash and its phase), its exact facts (cap, join, miter limit,
/// number of dashes) and half its widest extent.
///
/// The pen is the line-width circle mapped by the CTM: an ellipse, given
/// by its horizontal and vertical extents and their correlation, which do
/// not change when the CTM flips or turns the user space (pagelayout's
/// y-down CTM draws the same strokes as Prawn's y-up one).
fn pen(
  state : @pdflite.PdfContentOperatorState,
  ctm : @geometry.TransformMatrix,
) -> (Array[Double], Map[String, Json], Double) {
  let ps = state.path_state
  let w = ps.line_width
  let sxx = w * w * (ctm.a * ctm.a + ctm.c * ctm.c)
  let syy = w * w * (ctm.b * ctm.b + ctm.d * ctm.d)
  let sxy = w * w * (ctm.a * ctm.b + ctm.c * ctm.d)
  let wx = sxx.sqrt()
  let wy = syy.sqrt()
  let widest = if wx > wy { wx } else { wy }
  let lengths = [wx, wy, if widest > 0.0 { sxy / widest } else { 0.0 }]
  let scale = scale_of(ctm)
  for x in ps.dash_pattern.array {
    lengths.push(x * scale)
  }
  // the phase only matters with a dash
  lengths.push(
    if ps.dash_pattern.array.is_empty() {
      0.0
    } else {
      ps.dash_pattern.phase * scale
    },
  )
  let exact : Map[String, Json] = Map([])
  exact["cap"] = ps.line_cap.to_json()
  exact["join"] = ps.line_join.to_json()
  if ps.line_join == 0 {
    exact["miter_limit"] = state.miter_limit.to_json()
  }
  exact["dashes"] = ps.dash_pattern.array.length().to_json()
  let half = w /
    2.0 *
    (ctm.a * ctm.a + ctm.b * ctm.b).max(ctm.c * ctm.c + ctm.d * ctm.d).sqrt()
  (lengths, exact, half)
}

///|
/// The soft mask in effect, if any: its type and backdrop, and what its
/// group shows (the glyphs' text and the kinds of marks).
fn soft_mask(
  doc : @pdflite.PdfDocument,
  state : @pdflite.PdfContentOperatorState,
) -> Json? {
  let mask = match state.soft_mask {
    PdfIndirect(n) => doc.lookup_object_or_null(n)
    other => other
  }
  guard mask is PdfDictionary(_) else { return None }
  let out : Map[String, Json] = Map([])
  for key in ["S", "BC"] {
    match lookup(doc, mask, key) {
      Some(v) => out[key] = object_json(doc, v)
      None => ()
    }
  }
  match lookup(doc, mask, "G") {
    Some(group) => {
      let inner : Walk = {
        doc,
        glyphs: [],
        marks: [],
        order: 0,
        clip: None,
        clips: [],
      }
      let plain = { ..state, soft_mask: @syntax.PdfNull, }
      inner.form(plain, @syntax.pdf_dictionary([]), group) catch {
        _ => ()
      }
      out["text"] = text_of(inner.glyphs).to_json()
      out["marks"] = kinds(inner.marks).to_json()
    }
    None => ()
  }
  Some(Json::object(out))
}

///|
/// `ctm` is the CTM the path was built under.
fn Walk::path(
  self : Walk,
  state : @pdflite.PdfContentOperatorState,
  drawn : @shape.PdfDrawnPath,
  ctm : @geometry.TransformMatrix,
) -> Unit {
  let (points, exact) = path_geometry(drawn, ctm)
  let mut lengths : Array[Double] = []
  let paints : Array[Paint] = []
  let mut extent = bounds_of(points)
  if drawn.stroked {
    let (pen_lengths, pen_exact, half) = pen(state, ctm)
    lengths = pen_lengths
    for k, v in pen_exact {
      exact[k] = v
    }
    // what the stroke covers, for paint order
    extent = {
      x0: extent.x0 - half,
      y0: extent.y0 - half,
      x1: extent.x1 + half,
      y1: extent.y1 + half,
    }
    paints.push(stroke_paint(state))
  }
  match soft_mask(self.doc, state) {
    Some(mask) => exact["soft_mask"] = mask
    None => ()
  }
  if drawn.filled {
    paints.push(fill_paint(state))
  }
  self.marks.push({
    kind: "path",
    points,
    lengths,
    paints,
    exact: Json::object(exact),
    clip: self.clip,
    blend: blend_name(self.doc, state.blend_mode),
    extent,
    order: self.next_order(),
  })
}

///|
fn Walk::image(
  self : Walk,
  state : @pdflite.PdfContentOperatorState,
  kind : String,
  exact : Json,
) -> Unit {
  let points = corners(state.ctm, {
    min_x: 0.0,
    min_y: 0.0,
    max_x: 1.0,
    max_y: 1.0,
  })
  self.marks.push({
    kind,
    points,
    lengths: [],
    // an image is painted with the fill alpha
    paints: [
      { space: "image", values: [], alpha: state.alpha_constant_non_stroke, },
    ],
    exact,
    clip: self.clip,
    blend: blend_name(self.doc, state.blend_mode),
    extent: bounds_of(points),
    order: self.next_order(),
  })
}

///|
fn lookup(
  doc : @pdflite.PdfDocument,
  dict : @syntax.PdfObject,
  key : String,
) -> @syntax.PdfObject? {
  let key = if key.has_prefix("/") { key } else { "/" + key }
  doc.lookup_direct(pdf_name(key), dict)
}

///|
fn number(obj : @syntax.PdfObject) -> Double {
  match obj {
    PdfInteger(n) => n.to_double()
    PdfReal(x) => x
    _ => 0.0
  }
}

///|
fn is_path_construction(op : @content.PdfContentOp) -> Bool {
  match op {
    Op_W
    | Op_Wstar
    | Op_m(_)
    | Op_l(_)
    | Op_c(_)
    | Op_v(_)
    | Op_y(_)
    | Op_h
    | Op_re(_) => true
    _ => false
  }
}

///|
/// Walks content operators from `initial`, collecting what they show; the
/// state after them.
fn Walk::ops(
  self : Walk,
  initial : @pdflite.PdfContentOperatorState,
  resources : @syntax.PdfObject,
  ops : Array[@content.PdfContentOp],
) -> @pdflite.PdfContentOperatorState raise {
  let doc = self.doc
  let mut state = initial
  let mut clipping = false
  // the points of the path under construction, in page space (for clips),
  // and the CTM it is built under
  let building : Array[Double] = []
  let mut path_ctm = state.ctm
  // what glyphs shown in a clipping render mode (4 to 7) cover; they clip
  // at ET
  let mut text_clip : Rect? = None
  for op in ops {
    if building.is_empty() && is_path_construction(op) {
      path_ctm = state.ctm
    }
    let add = fn(x : Double, y : Double) {
      let p = state.ctm.apply(@geometry.point2(x, y))
      building.push(p.x)
      building.push(p.y)
    }
    match op {
      Op_m(x, y) | Op_l(x, y) => add(x, y)
      Op_c(x1, y1, x2, y2, x3, y3) => {
        add(x1, y1)
        add(x2, y2)
        add(x3, y3)
      }
      Op_v(x2, y2, x3, y3) | Op_y(x2, y2, x3, y3) => {
        add(x2, y2)
        add(x3, y3)
      }
      Op_re(x, y, w, h) => {
        add(x, y)
        add(x + w, y + h)
        add(x, y + h)
        add(x + w, y)
      }
      _ => ()
    }
    match op {
      Op_Tj(_) | Op_TJ(_) | Op_quote(_) | Op_double_quote(_, _, _) => {
        let first = self.glyphs.length()
        self.show(state, op)
        if state.text_state.rendering_mode >= 4 {
          for g in self.glyphs[first:] {
            text_clip = Some(
              match text_clip {
                None => g.extent
                Some(r) =>
                  {
                    x0: r.x0.min(g.extent.x0),
                    y0: r.y0.min(g.extent.y0),
                    x1: r.x1.max(g.extent.x1),
                    y1: r.y1.max(g.extent.y1),
                  }
              },
            )
          }
        }
      }
      Op_ET =>
        match text_clip {
          Some(r) => {
            self.clip = Some(intersect(self.clip, r))
            text_clip = None
          }
          None => ()
        }
      Op_q => self.clips.push(self.clip)
      Op_Q => self.clip = self.clips.pop().unwrap_or(None)
      Op_W | Op_Wstar => clipping = true
      Op_InlineImage(dict, _, data) =>
        self.image(state, "inline-image", {
          "dictionary": object_json(doc, dict),
          "data": fnv(data).to_json(),
        })
      Op_Do(name) => {
        let xobject = lookup(doc, resources, "XObject").bind(x => {
          lookup(doc, x, name_text(name))
        })
        guard xobject is Some(xobject) else {
          fail("no XObject \{name_text(name)}")
        }
        match lookup(doc, xobject, "Subtype") {
          Some(PdfNameObject(subtype)) if name_text(subtype) == "Form" => {
            self.form(state, resources, xobject)
            continue
          }
          _ => self.image(state, "image", object_json(doc, xobject))
        }
      }
      _ => ()
    }
    let result = doc.content_apply_resource_op(state, resources, op)
    for entry in result.entries {
      match entry.object {
        PdfContentPathObject(path) => self.path(result.state, path, path_ctm)
        PdfContentShadingObject(name) =>
          self.marks.push({
            kind: "shading",
            // where the shading's space lands: the unit square under the CTM
            points: corners(state.ctm, {
              min_x: 0.0,
              min_y: 0.0,
              max_x: 1.0,
              max_y: 1.0,
            }),
            lengths: [],
            paints: [],
            exact: match
              lookup(doc, resources, "Shading").bind(s => lookup(doc, s, name)) {
              Some(shading) => object_json(doc, shading)
              None => Json::null()
            },
            clip: self.clip,
            blend: blend_name(doc, result.state.blend_mode),
            extent: self.clip.unwrap_or({ x0: 0.0, y0: 0.0, x1: 0.0, y1: 0.0, }),
            order: self.next_order(),
          })
        // images and glyphs are recorded above
        PdfContentImageObject(_)
        | PdfContentInlineImageObject
        | PdfContentGlyphObject(_) => ()
      }
    }
    // the path a W marked becomes part of the clip when the path ends
    // (usually with n); its bounding box stands for it
    if is_painting(op) || op is Op_n {
      if clipping && building.length() > 0 {
        self.clip = Some(intersect(self.clip, bounds_of(building)))
      }
      clipping = false
      building.clear()
    }
    state = result.state
  }
  state
}

///|
/// A form XObject's content, painted as if in `q … Q`.
fn Walk::form(
  self : Walk,
  state : @pdflite.PdfContentOperatorState,
  resources : @syntax.PdfObject,
  form : @syntax.PdfObject,
) -> Unit raise {
  let doc = self.doc
  let matrix : @geometry.TransformMatrix = match lookup(doc, form, "Matrix") {
    Some(PdfArray(items)) if items.length() == 6 => {
      let n = items.map(number)
      { a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5], }
    }
    _ => { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0, }
  }
  let ctm = @geometry.transform_matrix_compose(state.ctm, matrix)
  let saved = self.clip
  self.clips.push(saved)
  match lookup(doc, form, "BBox") {
    Some(box) => {
      let r = doc.parse_rectangle(box)
      self.clip = Some(intersect(self.clip, bounds_of(corners(ctm, r))))
    }
    None => ()
  }
  let form_resources = lookup(doc, form, "Resources").unwrap_or(resources)
  let ops = doc.parse_content_ops_with_resources(form_resources, [form])
  // fonts are resource names: the form's own, not the page's cached ones
  let inner = {
    ..state,
    ctm,
    text_state: { ..state.text_state, font_cache: [], },
  }
  self.ops(inner, form_resources, ops) |> ignore
  self.clip = self.clips.pop().unwrap_or(saved)
}

///|
/// Inspects every page of a PDF.
pub fn inspect(bytes : Bytes) -> Array[PageView] raise {
  let doc = @pdflite.pdf_decompress_pdf(
    @pdflite.pdf_read_document_from_bytes(bytes),
  )
  doc.pages_of_pagetree().map(page => inspect_page(doc, page))
}

///|
fn inspect_page(
  doc : @pdflite.PdfDocument,
  page : @page.PdfPage,
) -> PageView raise {
  let box = doc.parse_rectangle(page.mediabox)
  let ops = doc.parse_content_ops_with_resources(page.resources, page.content)
  let state = @pdflite.pdf_content_initial_operator_state(
    box.min_x,
    box.min_y,
    box.max_x,
    box.max_y,
  )
  let walk : Walk = {
    doc,
    glyphs: [],
    marks: [],
    order: 0,
    clip: None,
    clips: [],
  }
  walk.ops(state, page.resources, ops) |> ignore
  {
    width: box.max_x - box.min_x,
    height: box.max_y - box.min_y,
    rotate: @page.pdf_page_int_of_rotation(page.rotate),
    glyphs: walk.glyphs,
    marks: walk.marks,
  }
}
