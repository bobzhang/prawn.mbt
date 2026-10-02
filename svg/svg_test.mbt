///|
/// An environment with one font whose glyphs are all half an em wide.
fn test_env(files? : Map[String, Bytes] = {}) -> @svg.Environment {
  {
    families: [("Noto Serif", ["normal", "bold"]), ("Helvetica", ["normal"])],
    load_font: (family, subfamily) => {
      Some({
        index: if family == "Helvetica" {
          2
        } else if subfamily == "bold" {
          1
        } else {
          0
        },
        advances: (text, size) => Array::make(text.length(), size / 2.0),
        height: size => size * 1.2,
      })
    },
    fallback_font: "Noto Serif",
    read_file: path => files.get(path),
    ambient_font_size: 10.5,
  }
}

///|
fn render(
  text : String,
  bounds? : (Double, Double) = (400, 800),
) -> Array[@pagelayout.GraphicOp] raise {
  let doc = @svg.SvgDocument::parse(text, bounds)
  doc.render(
    test_env(),
    origin=(0, 0),
    page_height=800,
    stack=@svg.TransformationStack::new(),
  )
}

///|
test "sizing: width, height and viewBox, with px at 0.75pt" {
  let doc = @svg.SvgDocument::parse(
    "<svg xmlns='http://www.w3.org/2000/svg' width='200px' height='100' viewBox='0 0 20 20'/>",
    (500, 700),
  )
  let s = doc.sizing
  inspect(
    "\{s.output_width} \{s.output_height} \{s.x_scale} \{s.y_scale} \{s.x_offset} \{s.y_offset}",
    content=(
      #|150 100 5 5 -5 0
    ),
  )
  // only a viewBox: the bounds' width
  let doc = @svg.SvgDocument::parse("<svg viewBox='0 0 50 25'/>", (400, 700))
  inspect(
    "\{doc.sizing.output_width} \{doc.sizing.output_height}",
    content="400 200",
  )
  doc.sizing.resize(height=100)
  inspect(
    "\{doc.sizing.output_width} \{doc.sizing.output_height}",
    content="200 100",
  )
  // preserveAspectRatio: slice, aligned to the right
  let a = @svg.AspectRatio::new(Some("xMaxYMid slice"), (100, 50), (10, 10))
  inspect(
    "\{a.width} \{a.height} \{a.x} \{a.y} \{a.slice}",
    content="100 100 0 -25 true",
  )
}

///|
test "a rectangle: fill, stroke and the viewBox transformation" {
  let ops = render(
    "<svg width='20' height='10' viewBox='0 0 40 20'><rect x='1' y='2' width='3' height='4' fill='red' stroke='#00f' stroke-width='2'/></svg>",
  )
  debug_inspect(
    ops,
    content=(
      #|[
      #|  Save,
      #|  Clip([Rectangle(0, 0, 20, 10)], NonZero),
      #|  Transform({ a: 0.5, b: 0, c: 0, d: 0.5, e: 0, f: 0 }),
      #|  Transform({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }),
      #|  Save,
      #|  Path(
      #|    {
      #|      segments: [Rectangle(1, 2, 3, 4)],
      #|      fill: Some(Solid({ r: 255, g: 0, b: 0 })),
      #|      fill_rule: NonZero,
      #|      stroke: Some(Solid({ r: 0, g: 0, b: 255 })),
      #|      stroke_style: {
      #|        width: Width(2),
      #|        cap: ButtCap,
      #|        join: MiterJoin,
      #|        miter_limit: 10,
      #|        dash: [],
      #|        dash_phase: 0,
      #|      },
      #|    },
      #|  ),
      #|  Restore,
      #|  Restore,
      #|]
    ),
  )
}

///|
test "stroke width 0 is a hairline; text outlines take the whole stroke style" {
  let ops = render(
    "<svg width='100' height='100'><line x1='0' y1='0' x2='10' y2='10' stroke='black' stroke-width='0'/><text x='5' y='20' fill='none' stroke='red' stroke-width='0.5' stroke-dasharray='2 1' stroke-linecap='round'>A</text></svg>",
  )
  guard ops.iter().find_first(op => op is Path(_)) is Some(Path(path)) else {
    fail("no path")
  }
  debug_inspect(path.stroke_style.width, content="Hairline")
  guard ops.iter().find_first(op => op is PaintedText(_))
    is Some(PaintedText(_, paint)) else {
    fail("no outlined text")
  }
  debug_inspect(
    paint,
    content=(
      #|{
      #|  fill: false,
      #|  stroke: Some({ r: 255, g: 0, b: 0 }),
      #|  stroke_style: {
      #|    width: Width(0.5),
      #|    cap: RoundCap,
      #|    join: MiterJoin,
      #|    miter_limit: 10,
      #|    dash: [2, 1],
      #|    dash_phase: 0,
      #|  },
      #|}
    ),
  )
}

///|
test "path data: relative commands, smooth and quadratic curves, arcs" {
  let ops = render(
    "<svg width='100' height='100'><path d='m10 10 h10 v10 q5 5 10 0 t10 0 s5 5 10 0 a5 5 0 0 1 10 0 z' fill='none' stroke='black'/></svg>",
  )
  guard ops.iter().find_first(op => op is Path(_)) is Some(Path(path)) else {
    fail("no path")
  }
  let rounded = path.segments.map(s => {
    match s {
      MoveTo(x, y) => "M\{x.round()},\{y.round()}"
      LineTo(x, y) => "L\{x.round()},\{y.round()}"
      CurveTo(_, _, _, _, x, y) => "C\{x.round()},\{y.round()}"
      Close => "Z"
      Rectangle(_, _, _, _) => "R"
    }
  })
  inspect(
    rounded.join(" "),
    content="M10,10 L20,10 L20,20 C30,20 C40,20 C50,20 C55,15 C60,20 Z",
  )
}

///|
test "styles: a stylesheet, then the style attribute, then attributes" {
  let ops = render(
    "<svg width='10' height='10'><style>.a { fill: blue; stroke: green } #b { fill: yellow }</style><rect class='a' id='b' style='fill: red' fill='#123456' width='5' height='5'/><rect class='a' width='5' height='5'/></svg>",
  )
  let paints = ops
    .filter(op => op is Path(_))
    .map(op => {
      match op {
        Path(p) => "\{Repr(p.fill)} \{Repr(p.stroke)}"
        _ => ""
      }
    })
  debug_inspect(
    paints,
    content=(
      #|[
      #|  "Some(Solid({ r: 18, g: 52, b: 86 })) Some(Solid({ r: 0, g: 128, b: 0 }))",
      #|  "Some(Solid({ r: 0, g: 0, b: 255 })) Some(Solid({ r: 0, g: 128, b: 0 }))",
      #|]
    ),
  )
}

///|
test "text: fonts, anchors and the cursor" {
  let ops = render(
    "<svg width='100' height='40'><text x='50' y='20' font-size='10' text-anchor='middle'>ab<tspan font-weight='bold'>cd</tspan></text><text x='0' y='30' font-family='sans-serif' font-size='8'>x</text></svg>",
  )
  let runs = ops
    .filter(op => op is Text(_))
    .map(op => {
      match op {
        Text(r) =>
          "\{r.text}@\{r.x_pt},\{r.baseline_pt} font \{r.font} size \{r.size_pt}"
        _ => ""
      }
    })
  debug_inspect(
    runs,
    content=(
      #|[
      #|  "ab@45,20 font 2 size 10",
      #|  "cd@45,20 font 2 size 10",
      #|  "x@0,30 font 2 size 8",
      #|]
    ),
  )
}

///|
test "warnings: unknown elements and unsupported values" {
  let doc = @svg.SvgDocument::parse(
    "<svg width='10' height='10'><foo/><rect width='0' height='5'/><circle/><path d='M0 0 L'/><rect width='1' height='1' stroke-dasharray='-1'/></svg>",
    (100, 100),
  )
  ignore(
    doc.render(
      test_env(),
      origin=(0, 0),
      page_height=100,
      stack=@svg.TransformationStack::new(),
    ),
  )
  debug_inspect(
    doc.warnings,
    content=(
      #|[
      #|  "Unknown tag 'foo'; ignoring",
      #|  "Invalid attributes on tag rect; skipping tag",
      #|  "Must have attributes r on tag circle; skipping tag",
      #|  "stroke-dasharray cannot have negative numbers; treating as 'none'",
      #|]
    ),
  )
}

///|
test "invalid XML and invalid sizing" {
  try @svg.SvgDocument::parse("<svg><rect></svg>", (10, 10)) catch {
    @svg.SvgError(message) =>
      inspect(message, content="mismatched end tag </svg> for <rect>")
  } noraise {
    _ => fail("expected an error")
  }
  let doc = @svg.SvgDocument::parse("<svg width='0' height='10'/>", (10, 10))
  let ops = doc.render(
    test_env(),
    origin=(0, 0),
    page_height=10,
    stack=@svg.TransformationStack::new(),
  )
  inspect(ops.length(), content="0")
  debug_inspect(
    doc.warnings,
    content=(
      #|["Zero or negative sizing data means this SVG cannot be rendered"]
    ),
  )
}

///|
test "values: Ruby's to_f and comma-whitespace lists" {
  inspect(@svg.ruby_to_f(" -1.5e2px"), content="-150")
  inspect(@svg.ruby_to_f(".5."), content="0.5")
  inspect(@svg.ruby_to_f("abc"), content="0")
  debug_inspect(
    @svg.split_comma_wsp("1, 2 3,4  ,5"),
    content=(
      #|["1", "2", "3", "4", "5"]
    ),
  )
  inspect(@svg.to_pixels("2in", 100), content="144")
  inspect(@svg.to_pixels("50%", 30), content="15")
  inspect(@svg.to_pixels("2em", 0, font_size=10), content="20")
}
