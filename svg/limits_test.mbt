///|
// Hostile input: circular references, deep nesting and exponential
// expansion must end in a warning or an error, never in a crash or a hang.

///|
/// Render `text`, returning the number of ops and the warnings.
fn render_warnings(
  text : String,
  files? : Map[String, Bytes] = {},
) -> (Int, Array[String]) raise {
  let doc = @svg.SvgDocument::parse(text, (100, 100))
  let ops = doc.render(
    test_env(files~),
    origin=(0, 0),
    page_height=100,
    stack=@svg.TransformationStack::new(),
  )
  (ops.length(), doc.warnings)
}

///|
test "a use inside the element it references is skipped" {
  let (_, warnings) = render_warnings(
    "<svg width='10' height='10'><g id='loop'><use href='#loop'/></g></svg>",
  )
  debug_inspect(
    warnings,
    content=(
      #|["use tag has a circular reference to '#loop'; skipping tag"]
    ),
  )
}

///|
test "mutually referencing uses are expanded once" {
  let (ops, warnings) = render_warnings(
    "<svg width='10' height='10'><g id='a'><rect width='1' height='1'/><use href='#b'/></g><g id='b'><use xlink:href='#a'/></g></svg>",
  )
  debug_inspect(
    warnings,
    content=(
      #|[
      #|  "use tag has a circular reference to '#a'; skipping tag",
      #|  "use tag has a circular reference to '#b'; skipping tag",
      #|]
    ),
  )
  inspect(ops > 0, content="true")
}

///|
test "a symbol that uses itself" {
  // once where it is defined (not drawn), once where it is used
  let (_, warnings) = render_warnings(
    "<svg width='10' height='10'><defs><symbol id='s' viewBox='0 0 1 1'><use href='#s'/></symbol></defs><use href='#s'/></svg>",
  )
  debug_inspect(
    warnings,
    content=(
      #|[
      #|  "use tag has a circular reference to '#s'; skipping tag",
      #|  "use tag has a circular reference to '#s'; skipping tag",
      #|]
    ),
  )
}

///|
test "exponential use expansion is bounded" {
  // each level uses the previous one ten times: 10^12 rectangles
  let sb = StringBuilder()
  sb.write_string(
    "<svg width='10' height='10'><defs><rect id='l0' width='1' height='1'/>",
  )
  for i in 1..<=12 {
    sb.write_string("<g id='l\{i}'>")
    for _ in 0..<10 {
      sb.write_string("<use href='#l\{i - 1}'/>")
    }
    sb.write_string("</g>")
  }
  sb.write_string("</defs><use href='#l12'/></svg>")
  let (_, warnings) = render_warnings(sb.to_string())
  debug_inspect(
    warnings,
    content=(
      #|["SVG is too complex to render in full; skipping the rest of it"]
    ),
  )
}

///|
test "a long chain of distinct uses is bounded" {
  let sb = StringBuilder()
  sb.write_string("<svg width='10' height='10'><defs>")
  sb.write_string("<rect id='u0' width='1' height='1'/>")
  for i in 1..<=20000 {
    sb.write_string("<use id='u\{i}' href='#u\{i - 1}'/>")
  }
  sb.write_string("</defs><use href='#u20000'/></svg>")
  // each use of the chain in defs expands the chain below it (as deep as
  // allowed), quadratic work that the budget cuts short
  let (_, warnings) = render_warnings(sb.to_string())
  debug_inspect(
    warnings,
    content=(
      #|[
      #|  "SVG elements are nested too deeply; skipping the deepest ones",
      #|  "SVG is too complex to render in full; skipping the rest of it",
      #|]
    ),
  )
}

///|
test "deeply nested elements are an error" {
  let depth = 100000
  let sb = StringBuilder()
  sb.write_string("<svg width='10' height='10'>")
  for _ in 0..<depth {
    sb.write_string("<g>")
  }
  for _ in 0..<depth {
    sb.write_string("</g>")
  }
  sb.write_string("</svg>")
  try @svg.SvgDocument::parse(sb.to_string(), (10, 10)) catch {
    @svg.SvgError(message) =>
      inspect(message, content="elements are nested more than 256 deep")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "elements nested as deep as allowed render" {
  let depth = 255
  let sb = StringBuilder()
  sb.write_string(
    "<svg width='10' height='10'><clipPath id='c'><rect width='1' height='1'/></clipPath>",
  )
  for _ in 0..<(depth - 2) {
    sb.write_string("<g transform='translate(1)' opacity='0.9'>")
  }
  sb.write_string("<rect width='1' height='1' clip-path='url(#c)'/>")
  for _ in 0..<(depth - 2) {
    sb.write_string("</g>")
  }
  sb.write_string("</svg>")
  let (ops, warnings) = render_warnings(sb.to_string())
  debug_inspect(warnings, content="[]")
  inspect(ops > 0, content="true")
}

///|
test "circular gradient references" {
  // the first rectangle reads a (and through it b), then a and b are read
  // again where they are defined; each time the chain is cut where it
  // leads back
  let (_, warnings) = render_warnings(
    "<svg width='10' height='10'><rect width='5' height='5' fill='url(#a)'/><linearGradient id='a' href='#b'/><linearGradient id='b' xlink:href='#a'/><linearGradient id='c' href='#c'><stop offset='0' stop-color='red'/></linearGradient><rect width='5' height='5' fill='url(#c)'/></svg>",
  )
  debug_inspect(
    warnings,
    content=(
      #|[
      #|  "gradient has a circular reference to '#a'; ignoring it",
      #|  "gradient does not have any valid stops",
      #|  "gradient does not have any valid stops",
      #|  "gradient has a circular reference to '#a'; ignoring it",
      #|  "gradient does not have any valid stops",
      #|  "gradient does not have any valid stops",
      #|  "gradient has a circular reference to '#b'; ignoring it",
      #|  "gradient does not have any valid stops",
      #|  "gradient does not have any valid stops",
      #|  "gradient has a circular reference to '#c'; ignoring it",
      #|]
    ),
  )
}

///|
test "a tref that refers to the text it is in" {
  let (_, warnings) = render_warnings(
    "<svg width='10' height='10'><text id='t' x='1' y='5'>a<tref href='#t'/></text></svg>",
  )
  debug_inspect(
    warnings,
    content=(
      #|["tref tag has a circular reference to '#t'; skipping tag"]
    ),
  )
}

///|
test "an SVG image that draws itself" {
  let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='1' height='1'/><image href='self.svg' width='10' height='10'/></svg>"
  let (ops, warnings) = render_warnings(svg, files={
    "self.svg": @utf8.encode(svg),
  })
  inspect(ops > 0, content="true")
  debug_inspect(
    warnings,
    content=(
      #|["SVG images are nested more than 8 deep; skipping tag"]
    ),
  )
}

///|
test "entity expansion is bounded" {
  let sb = StringBuilder()
  sb.write_string("<!DOCTYPE svg [<!ENTITY a0 'xxxxxxxxxx'>")
  for i in 1..<=8 {
    let r = "&a\{i - 1};"
    sb.write_string(
      "<!ENTITY a\{i} '\{r}\{r}\{r}\{r}\{r}\{r}\{r}\{r}\{r}\{r}'>",
    )
  }
  sb.write_string("]><svg width='10' height='10'><text>&a8;</text></svg>")
  try @svg.SvgDocument::parse(sb.to_string(), (10, 10)) catch {
    @svg.SvgError(message) =>
      inspect(message, content="entity expansion has grown too large")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "long path data" {
  let sb = StringBuilder()
  sb.write_string("<svg width='10' height='10'><path d='M0 0")
  for i in 0..<100000 {
    sb.write_string(" L\{i % 10} \{i % 7}")
  }
  sb.write_string("'/></svg>")
  let (ops, warnings) = render_warnings(sb.to_string())
  debug_inspect(warnings, content="[]")
  inspect(ops > 0, content="true")
}
