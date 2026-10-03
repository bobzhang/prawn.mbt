///|
/// A one-page PDF (612 × 792) showing `content`, with Helvetica as /F1 and
/// `resources` (dictionary entries) added to its resources.
fn pdf(content : String, resources? : String = "") -> Bytes {
  let objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> \{resources} >> >>",
    "<< /Length \{content.length()} >>\nstream\n\{content}\nendstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
  ]
  let out = StringBuilder()
  out.write_string("%PDF-1.4\n")
  let offsets : Array[Int] = []
  for i, body in objects {
    offsets.push(out.to_string().length())
    out.write_string("\{i + 1} 0 obj\n\{body}\nendobj\n")
  }
  let xref = out.to_string().length()
  out.write_string("xref\n0 \{objects.length() + 1}\n0000000000 65535 f \n")
  for offset in offsets {
    let digits = offset.to_string()
    out.write_string("0000000000"[:10 - digits.length()].to_owned() + digits)
    out.write_string(" 00000 n \n")
  }
  out.write_string(
    "trailer\n<< /Size \{objects.length() + 1} /Root 1 0 R >>\nstartxref\n\{xref}\n%%EOF\n",
  )
  let text = out.to_string()
  let bytes = Array::make(text.length(), b'\x00')
  for i in 0..<text.length() {
    bytes[i] = text[i].to_int().to_byte()
  }
  Bytes::from_array(bytes)
}

///|
fn differs(a : String, b : String, resources? : String = "") -> Bool raise {
  !@inspect.compare(
    @inspect.inspect(pdf(a, resources~)),
    @inspect.inspect(pdf(b, resources~)),
  ).is_empty()
}

///|
test "the same content compares equal" {
  let c = "BT /F1 12 Tf 72 700 Td (Hello) Tj ET 0 0 100 100 re f"
  assert_false(differs(c, c))
}

///|
test "glyph origins, and ' moving one line" {
  let page = @inspect.inspect(
    pdf("BT /F1 10 Tf 14 TL 100 100 Td (A) Tj (B) ' ET"),
  )
  let glyphs = page[0].glyphs
  assert_eq(glyphs.map(g => g.text), ["A", "B"])
  assert_eq(glyphs[0].y, 100.0)
  assert_eq(glyphs[1].y, 86.0)
  assert_eq(glyphs[1].x, 100.0)
}

///|
test "text is black by default" {
  let g = @inspect.inspect(pdf("BT /F1 12 Tf 72 700 Td (A) Tj ET"))[0].glyphs[0]
  assert_eq(g.fill.map(p => p.values), Some([0.0]))
}

///|
test "paths are compared in page space" {
  // the same rectangle moved 100 pt by the CTM
  assert_true(differs("0 0 10 10 re f", "1 0 0 1 100 0 cm 0 0 10 10 re f"))
  // built before a scale, painted after: the CTM it was built under counts
  assert_true(
    differs("0 0 10 10 re 2 0 0 2 0 0 cm f", "2 0 0 2 0 0 cm 0 0 10 10 re f"),
  )
}

///|
test "equivalent paths compare equal" {
  assert_false(
    differs("0 0 100 100 re f", "0 0 m 100 0 l 100 100 l 0 100 l h f"),
  )
  assert_false(differs("0 0 100 100 re f", "0 0 m 100 0 l 100 100 l 0 100 l f"))
  assert_false(differs("[] 0 d 0 0 m 10 0 l S", "[] 10 d 0 0 m 10 0 l S"))
  // a stroke tells open from closed
  assert_true(differs("0 0 m 10 0 l 10 10 l S", "0 0 m 10 0 l 10 10 l h S"))
}

///|
test "non-uniform stroke widths" {
  assert_true(
    differs("10 w 0 0 m 100 0 l S", "2 0 0 0.5 0 0 cm 10 w 0 0 m 50 0 l S"),
  )
}

///|
test "clips" {
  assert_true(
    differs(
      "q 0 0 100 100 re W n 0 0 500 500 re f Q", "q 0 0 50 50 re W n 0 0 500 500 re f Q",
    ),
  )
  // another op between the path and W n does not lose the clip
  assert_true(
    differs(
      "q 0 0 100 100 re 1 w W n 0 0 500 500 re f Q", "q 0 0 50 50 re 1 w W n 0 0 500 500 re f Q",
    ),
  )
  // Q restores
  assert_false(differs("q 0 0 1 1 re W n Q 0 0 9 9 re f", "0 0 9 9 re f"))
}

///|
test "text in a clipping render mode clips at ET" {
  assert_true(
    differs(
      "0 0 500 500 re f BT /F1 12 Tf 7 Tr 72 700 Td (A) Tj ET", "BT /F1 12 Tf 7 Tr 72 700 Td (A) Tj ET 0 0 500 500 re f",
    ),
  )
}

///|
test "render modes choose the paints" {
  // fill and stroke (mode 2): both paints count
  assert_true(
    differs(
      "1 0 0 rg 0 0 1 RG BT /F1 12 Tf 2 Tr 72 700 Td (A) Tj ET", "0 1 0 rg 0 0 1 RG BT /F1 12 Tf 2 Tr 72 700 Td (A) Tj ET",
    ),
  )
  // stroke and clip (mode 5): the stroke counts
  assert_true(
    differs(
      "1 0 0 RG BT /F1 12 Tf 5 Tr 72 700 Td (A) Tj ET", "0 1 0 RG BT /F1 12 Tf 5 Tr 72 700 Td (A) Tj ET",
    ),
  )
}

///|
test "horizontal scaling and rotation" {
  assert_true(
    differs(
      "BT /F1 12 Tf 72 700 Td (A) Tj ET", "BT /F1 12 Tf 200 Tz 72 700 Td (A) Tj ET",
    ),
  )
  assert_true(
    differs(
      "BT /F1 12 Tf 1 0 0 1 72 700 Tm (A) Tj ET", "BT /F1 12 Tf 0 1 -1 0 72 700 Tm (A) Tj ET",
    ),
  )
}

///|
test "paint order of overlapping text and fills" {
  assert_true(
    differs(
      "BT /F1 12 Tf 72 700 Td (A) Tj ET 0 0 612 792 re f", "0 0 612 792 re f BT /F1 12 Tf 72 700 Td (A) Tj ET",
    ),
  )
}

///|
test "alpha and blend modes from ExtGState" {
  let resources = "/ExtGState << /G1 << /ca 0.5 >> /G2 << /BM /Multiply >> >>"
  assert_true(differs("0 0 10 10 re f", "/G1 gs 0 0 10 10 re f", resources~))
  assert_true(differs("0 0 10 10 re f", "/G2 gs 0 0 10 10 re f", resources~))
}

///|
test "inline images: data and alpha" {
  let resources = "/ExtGState << /G1 << /ca 0.1 >> >>"
  let black = "q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /G /BPC 8 ID \u{0} EI Q"
  let white = "q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /G /BPC 8 ID \u{ff} EI Q"
  assert_true(differs(black, white))
  assert_true(differs(black, "/G1 gs " + black, resources~))
}

///|
test "shadings: their definition and where their space lands" {
  let shading = fn(c1 : String) {
    "/Shading << /Sh1 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [\{c1}] /N 1 >> >> >>"
  }
  let paint = "q 0 0 100 100 re W n /Sh1 sh Q"
  assert_false(differs(paint, paint, resources=shading("0 1 0")))
  assert_true(
    !@inspect.compare(
      @inspect.inspect(pdf(paint, resources=shading("0 1 0"))),
      @inspect.inspect(pdf(paint, resources=shading("0 0 1"))),
    ).is_empty(),
  )
  assert_true(
    differs(paint, "2 0 0 2 0 0 cm " + paint, resources=shading("0 1 0")),
  )
}

///|
test "a flipped CTM draws the same stroke" {
  // pagelayout draws with y down (d = -1), Prawn with y up
  assert_false(
    differs(
      "2 w 0 100 m 100 100 l S", "1 0 0 -1 0 792 cm 2 w 0 692 m 100 692 l S",
    ),
  )
}

///|
test "stroked text keeps its dash, cap and join" {
  let text = "BT /F1 36 Tf 1 Tr 72 600 Td (A) Tj ET"
  assert_true(differs(text, "[3] 0 d " + text))
  assert_true(differs(text, "1 J " + text))
}

///|
test "miter limits count for mitered joins" {
  let path = "10 w 0 0 m 50 10 l 0 20 l S"
  assert_true(differs("10 M " + path, "1 M " + path))
}

///|
test "soft masks" {
  let resources = "/ExtGState << /M1 << /SMask << /S /Luminosity /G 6 0 R >> >> >>"
  // the mask's group is object 6, which this one-page PDF does not have: a
  // mask that is there at all must still show
  assert_true(differs("0 0 10 10 re f", "/M1 gs 0 0 10 10 re f", resources~))
}

///|
test "Q does not bring back a path painted inside q … Q" {
  // the rectangle is stroked inside q … Q; the fill after is the second
  // rectangle alone
  assert_false(
    differs(
      "0 0 10 10 re q S Q 20 20 10 10 re f", "0 0 10 10 re S 20 20 10 10 re f",
    ),
  )
}
