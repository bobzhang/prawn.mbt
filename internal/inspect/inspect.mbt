///|
/// What a page shows, in the terms the comparison judges (PLAN.md §3): its
/// size, every glyph and every mark (path, image, shading) in paint order.
pub(all) struct PageView {
  width : Double
  height : Double
  rotate : Int
  glyphs : Array[Glyph]
  marks : Array[Mark]
}

///|
/// One shown glyph. `x`/`y` are its origin on the baseline in page
/// coordinates (PDF points, y up), `size` the effective font size.
pub(all) struct Glyph {
  text : String
  font : String
  size : Double
  x : Double
  y : Double
  mode : Int
  space : String
  colour : Array[Double]
  alpha : Double
}

///|
/// A non-text mark: `kind` is "path", "image", "inline-image" or "shading";
/// `shape` its geometry (a path's segments, an image's placement), `style`
/// how it is painted (colours, line style, alpha, the image's properties).
pub(all) struct Mark {
  kind : String
  shape : Json
  style : Json
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
fn pdf_name(text : String) -> @core.PdfName {
  let bytes = Array::make(text.length(), b'\x00')
  for i in 0..<text.length() {
    bytes[i] = text[i].to_int().to_byte()
  }
  @core.pdf_name_of_bytes(Bytes::from_array(bytes))
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
fn point_json(m : @geometry.TransformMatrix, x : Double, y : Double) -> Json {
  let p = m.apply(@geometry.point2(x, y))
  [p.x, p.y]
}

///|
fn colour_json(
  space : @pdflite.PdfColourSpace,
  values : @pdflite.PdfContentColourValues,
) -> Json {
  {
    "space": space_name(space).to_json(),
    "values": colour_values(values).to_json(),
  }
}

///|
/// The properties of an image XObject the comparison checks: its
/// dictionary entries that change how it looks, and a hash of its data
/// (decoded where pdflite decodes it; a DCT stream's own bytes otherwise).
fn image_style(
  doc : @pdflite.PdfDocument,
  resources : @syntax.PdfObject,
  name : String,
) -> Json {
  let xobjects = doc.lookup_direct(pdf_name("/XObject"), resources)
  guard xobjects is Some(dict) else { return { "missing": true } }
  guard doc.lookup_direct(pdf_name("/" + name), dict) is Some(image) else {
    return { "missing": true }
  }
  let entry = fn(key : String) -> Json {
    match doc.lookup_direct(pdf_name(key), image) {
      Some(obj) => object_json(doc, obj)
      None => Json::null()
    }
  }
  let data = match image {
    PdfStreamObject(_) => image.stream_bytes() catch { _ => b"" }
    _ => b""
  }
  {
    "width": entry("/Width"),
    "height": entry("/Height"),
    "bits": entry("/BitsPerComponent"),
    "colour_space": entry("/ColorSpace"),
    "decode": entry("/Decode"),
    "filter": entry("/Filter"),
    "mask": entry("/Mask"),
    "soft_mask": doc.lookup_direct(pdf_name("/SMask"), image) is Some(_),
    "data": fnv(data).to_json(),
  }
}

///|
/// A PDF object as JSON, following references (with a depth limit) and
/// leaving streams as their dictionaries.
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
    _ => ToJson::to_json(obj)
  }
}

///|
/// FNV-1a, 64-bit, as a hex string: enough to tell image data apart.
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
/// The render matrix of a glyph shown with text matrix `tm`: its origin is
/// the glyph's baseline origin in page space.
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
fn glyphs_of_show(
  state : @pdflite.PdfContentOperatorState,
  op : @content.PdfContentOp,
  out : Array[Glyph],
) -> Unit raise {
  let ts = state.text_state
  let font = ts.current_font
  let placed = ts.content_apply_text_op(font, state.ctm, op)
  let name = font_name(font)
  let stroking = ts.rendering_mode == 1 || ts.rendering_mode == 2
  let (space, values, alpha) = if stroking {
    (
      state.path_state.colourspace_stroke,
      state.path_state.colour_stroke,
      state.alpha_constant_stroke,
    )
  } else {
    (
      state.path_state.colourspace_non_stroke,
      state.path_state.colour_non_stroke,
      state.alpha_constant_non_stroke,
    )
  }
  for glyph in placed.glyphs {
    let m = render_matrix(state, glyph.text_matrix)
    let codepoints = font
      .text_extractor()
      .codepoints_of_text(font.content_bytes_of_charcode(glyph.charcode))
    let text = StringBuilder()
    for cp in codepoints {
      text.write_char(cp.unsafe_to_char())
    }
    out.push({
      text: text.to_string(),
      font: name,
      size: (m.c * m.c + m.d * m.d).sqrt(),
      x: m.e,
      y: m.f,
      mode: ts.rendering_mode,
      space: space_name(space),
      colour: colour_values(values),
      alpha,
    })
  }
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
  let glyphs : Array[Glyph] = []
  let marks : Array[Mark] = []
  let initial = @pdflite.pdf_content_initial_operator_state(
    box.min_x,
    box.min_y,
    box.max_x,
    box.max_y,
  )
  // The initial colour is black (PDF 32000-1:2008, 8.4.1); pdflite 0.3.2
  // starts from gray 1.0, which is white.
  let mut state = {
    ..initial,
    path_state: {
      ..initial.path_state,
      colour_stroke: PdfContentColourFloats([0.0]),
      colour_non_stroke: PdfContentColourFloats([0.0]),
    },
  }
  for op in ops {
    match op {
      Op_Tj(_) | Op_TJ(_) | Op_quote(_) | Op_double_quote(_, _, _) => {
        // ' and " move to the next line (and set spacing) first
        let before = match op {
          Op_quote(_) | Op_double_quote(_, _, _) =>
            doc.content_apply_resource_op(state, page.resources, Op_Tstar).state
          _ => state
        }
        glyphs_of_show(before, op, glyphs)
        state = doc.content_apply_resource_op(state, page.resources, op).state
        continue
      }
      _ => ()
    }
    let result = doc.content_apply_resource_op(state, page.resources, op)
    for entry in result.entries {
      match entry.object {
        PdfContentPathObject(path) => {
          let ps = result.state.path_state
          // only what paints this path: a stroke's line style and colour, a
          // fill's colour
          let style : Map[String, Json] = Map([])
          if path.stroked {
            style["stroke"] = colour_json(
              ps.colourspace_stroke,
              ps.colour_stroke,
            )
            style["line_width"] = ps.line_width.to_json()
            style["cap"] = ps.line_cap.to_json()
            style["join"] = ps.line_join.to_json()
            style["dash"] = ToJson::to_json(ps.dash_pattern)
            style["alpha_stroke"] = result.state.alpha_constant_stroke.to_json()
          }
          if path.filled {
            style["fill"] = colour_json(
              ps.colourspace_non_stroke,
              ps.colour_non_stroke,
            )
            style["alpha_fill"] = result.state.alpha_constant_non_stroke.to_json()
          }
          marks.push({
            kind: "path",
            shape: ToJson::to_json(path),
            style: Json::object(style),
          })
        }
        PdfContentImageObject(name) =>
          marks.push({
            kind: "image",
            shape: placement_json(state.ctm),
            style: image_style(doc, page.resources, name),
          })
        PdfContentInlineImageObject =>
          marks.push({
            kind: "inline-image",
            shape: placement_json(state.ctm),
            style: Json::null(),
          })
        PdfContentShadingObject(name) =>
          marks.push({
            kind: "shading",
            shape: name.to_json(),
            style: Json::null(),
          })
        PdfContentGlyphObject(_) => ()
      }
    }
    state = result.state
  }
  {
    width: box.max_x - box.min_x,
    height: box.max_y - box.min_y,
    rotate: @page.pdf_page_int_of_rotation(page.rotate),
    glyphs,
    marks,
  }
}

///|
/// Where an image's unit square lands: its corners in page space.
fn placement_json(ctm : @geometry.TransformMatrix) -> Json {
  [
    point_json(ctm, 0.0, 0.0),
    point_json(ctm, 1.0, 0.0),
    point_json(ctm, 1.0, 1.0),
    point_json(ctm, 0.0, 1.0),
  ]
}
