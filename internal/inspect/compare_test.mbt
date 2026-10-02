///|
fn glyph(
  text : String,
  x : Double,
  order : Int,
  fill? : @inspect.Paint? = Some(black),
  stroke? : @inspect.Paint? = None,
  matrix? : Array[Double] = [12.0, 0.0, 0.0, 12.0],
  blend? : String = "Normal",
) -> @inspect.Glyph {
  {
    text,
    font: "Helvetica",
    size: 12.0,
    matrix,
    x,
    y: 700.0,
    mode: if stroke is Some(_) {
      1
    } else {
      0
    },
    fill,
    stroke,
    line_width: None,
    clip: None,
    blend,
    extent: { x0: x, y0: 697.0, x1: x + 7.0, y1: 709.0, },
    order,
  }
}

///|
let black : @inspect.Paint = { space: "DeviceGray", values: [0.0], alpha: 1.0, }

///|
fn rect(
  x : Double,
  order : Int,
  exact? : Json = { "subpaths": ["lllh"] },
  kind? : String = "path",
) -> @inspect.Mark {
  {
    kind,
    points: [x, 690.0, x + 50.0, 690.0, x + 50.0, 720.0, x, 720.0],
    lengths: [],
    paints: [black],
    exact,
    clip: None,
    blend: "Normal",
    extent: { x0: x, y0: 690.0, x1: x + 50.0, y1: 720.0, },
    order,
  }
}

///|
fn page(
  glyphs : Array[@inspect.Glyph],
  marks : Array[@inspect.Mark],
) -> Array[@inspect.PageView] {
  [{ width: 612.0, height: 792.0, rotate: 0, glyphs, marks, }]
}

///|
test "identical pages agree" {
  let a = page([glyph("A", 100.0, 1)], [rect(100.0, 2)])
  assert_eq(@inspect.compare(a, a), [])
}

///|
test "positions within 0.01 pt agree, beyond do not" {
  let a = page([glyph("A", 100.0, 1)], [])
  assert_eq(@inspect.compare(a, page([glyph("A", 100.009, 1)], [])), [])
  assert_true(
    !@inspect.compare(a, page([glyph("A", 100.02, 1)], [])).is_empty(),
  )
}

///|
test "horizontal scaling and rotation show in the matrix" {
  let a = page([glyph("A", 100.0, 1)], [])
  let wide = page([glyph("A", 100.0, 1, matrix=[13.2, 0.0, 0.0, 12.0])], [])
  let turned = page([glyph("A", 100.0, 1, matrix=[0.0, 12.0, -12.0, 0.0])], [])
  assert_true(!@inspect.compare(a, wide).is_empty())
  assert_true(!@inspect.compare(a, turned).is_empty())
}

///|
test "stroke and fill paints are compared separately" {
  let red : @inspect.Paint = {
    space: "DeviceRGB",
    values: [1.0, 0.0, 0.0],
    alpha: 1.0,
  }
  let green : @inspect.Paint = {
    space: "DeviceRGB",
    values: [0.0, 1.0, 0.0],
    alpha: 1.0,
  }
  let a = page([glyph("A", 100.0, 1, fill=None, stroke=Some(red))], [])
  let b = page([glyph("A", 100.0, 1, fill=None, stroke=Some(green))], [])
  assert_true(!@inspect.compare(a, b).is_empty())
}

///|
test "blend modes are exact" {
  let a = page([glyph("A", 100.0, 1)], [])
  let b = page([glyph("A", 100.0, 1, blend="Multiply")], [])
  assert_true(!@inspect.compare(a, b).is_empty())
}

///|
test "image data is exact" {
  let a = page([], [rect(100.0, 1, kind="image", exact={ "data": "0011" })])
  let b = page([], [rect(100.0, 1, kind="image", exact={ "data": "0012" })])
  assert_true(!@inspect.compare(a, b).is_empty())
}

///|
test "overlapping text and marks keep their paint order" {
  // text then an opaque rectangle over it, vs the rectangle first
  let a = page([glyph("A", 110.0, 1)], [rect(100.0, 2)])
  let b = page([glyph("A", 110.0, 2)], [rect(100.0, 1)])
  assert_eq(@inspect.compare(a, b), [
    "page 1: glyph 0 (\"A\") should be painted before mark 0 (path)",
  ])
  // apart, their order does not matter
  let c = page([glyph("A", 300.0, 1)], [rect(100.0, 2)])
  let d = page([glyph("A", 300.0, 2)], [rect(100.0, 1)])
  assert_eq(@inspect.compare(c, d), [])
}

///|
test "page sizes are exact" {
  let a = page([], [])
  let b : Array[@inspect.PageView] = [
    { width: 612.005, height: 792.0, rotate: 0, glyphs: [], marks: [], },
  ]
  assert_true(!@inspect.compare(a, b).is_empty())
}
