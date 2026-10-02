///|
// oracle: runs an operation script (docs/op-scripts.md) through this
// module, as scripts/oracle/driver.rb runs it through Ruby Prawn.
//
//   oracle SCRIPT.json OUT.pdf OUT.jsonl
//
// Ops this module cannot run yet are logged as {"unsupported": NAME} and
// skipped, so the comparison shows what is missing.

///|
suberror ScriptError {
  ScriptError(String)
}

///|
priv struct Run {
  doc : @prawn.Document
  log : Array[Json]
}

///|
fn number(j : Json) -> Double raise ScriptError {
  match j {
    Number(x, ..) => x
    _ => raise ScriptError("not a number: \{j.stringify()}")
  }
}

///|
fn string(j : Json) -> String raise ScriptError {
  match j {
    // "::text" is the literal ":text"; ":name" is a symbol, not a string
    String(s) if s.has_prefix("::") => s[1:].to_owned()
    String(s) if s.has_prefix(":") && s.length() > 1 =>
      raise ScriptError("a symbol where a string goes: \{s}")
    String(s) => s
    _ => raise ScriptError("not a string: \{j.stringify()}")
  }
}

///|
/// A JSON string as the driver reads it: ":name" is a symbol, "::text" the
/// literal ":text".
fn symbol(j : Json) -> String? {
  match j {
    String(s) if s.has_prefix("::") => None
    String(s) if s.has_prefix(":") && s.length() > 1 => Some(s[1:].to_owned())
    _ => None
  }
}

///|
/// The options of an op, as the driver takes them: the keys beside `block`
/// in its trailing block object, or else the object before that, or its
/// trailing object.
fn options(args : Array[Json]) -> Map[String, Json] {
  let plain = fn(j : Json?) -> Map[String, Json] {
    match j {
      Some(Object(map)) if !map.contains("trace") && !map.contains("block") =>
        map
      _ => Map([])
    }
  }
  match args.last() {
    Some(Object(map)) if map.contains("block") => {
      let out = Map([])
      for k, v in map {
        if k != "block" {
          out[k] = v
        }
      }
      if out.is_empty() && args.length() >= 2 {
        plain(Some(args[args.length() - 2]))
      } else {
        out
      }
    }
    last => plain(last)
  }
}

///|
fn alignment(j : Json?) -> @prawn.Alignment raise ScriptError {
  match j.bind(symbol) {
    None | Some("left") => Left
    Some("center") => Center
    Some("right") => Right
    Some("justify") => Justify
    Some(other) => raise ScriptError("align \{other}")
  }
}

///|
/// Whether `opts` has only the options in `known` (an op given others is
/// one this module cannot run faithfully yet).
fn only(opts : Map[String, Json], known : Array[String]) -> Bool {
  opts.keys().all(k => known.contains(k))
}

///|
/// Runs op `name` with `args`; its value (for a `?` query), or None when
/// this module cannot run it. Prawn's errors propagate.
fn Run::call(self : Run, name : String, args : Array[Json]) -> Json? raise {
  let doc = self.doc
  let opts = options(args)
  match name {
    // kerning is Prawn's default (`default_kerning`), and how Flow sets text
    "text" if only(opts, ["size", "align", "leading", "kerning"]) &&
      !(opts.get("kerning") is Some(False)) => {
      doc.text(
        string(args[0]),
        size?=opts.get("size").map(number),
        align=alignment(opts.get("align")),
        leading=opts.get("leading").map(number).unwrap_or(0.0),
      )
      Some(Json::null())
    }
    "move_down" => {
      doc.move_down(number(args[0]))
      Some(Json::null())
    }
    "font_size" if args.length() == 1 => {
      doc.set_font_size(number(args[0]))
      Some(Json::null())
    }
    "start_new_page" if only(opts, ["layout", "size"]) => {
      doc.start_new_page(
        layout?=opts.get("layout").bind(symbol),
        size?=match opts.get("size") {
          Some(size) => Some(page_size(Some(size)))
          None => None
        },
      )
      Some(Json::null())
    }
    "width_of" if only(opts, ["size", "kerning"]) =>
      Some(
        doc
        .width_of(
          string(args[0]),
          size?=opts.get("size").map(number),
          kerning=opts.get("kerning") is Some(True),
        )
        .to_json(),
      )
    "height_of" if only(opts, ["size", "width", "leading"]) =>
      Some(
        doc
        .height_of(
          string(args[0]),
          size?=opts.get("size").map(number),
          width?=opts.get("width").map(number),
          leading=opts.get("leading").map(number).unwrap_or(0.0),
        )
        .to_json(),
      )
    "bounding_box" if only(opts, ["width", "height"]) &&
      block(args) is Some(ops) => {
      guard args[0] is Array([x, y]) else {
        raise ScriptError("bounding_box needs a point")
      }
      doc.bounding_box(
        (number(x), number(y)),
        number(opts.get("width").unwrap_or(Json::null())),
        height?=match opts.get("height") {
          None | Some(Null) => None
          Some(h) => Some(number(h))
        },
        () => self.ops(ops),
      )
      Some(Json::null())
    }
    "indent" if opts.is_empty() && block(args) is Some(ops) => {
      let right = if args.length() > 2 { number(args[1]) } else { 0.0 }
      doc.indent(number(args[0]), right~, () => self.ops(ops))
      Some(Json::null())
    }
    "float" if opts.is_empty() && block(args) is Some(ops) => {
      doc.float(() => self.ops(ops))
      Some(Json::null())
    }
    "bounds" => {
      let b = doc.bounds()
      Some({
        "left": b.left.to_json(),
        "bottom": b.bottom.to_json(),
        "width": b.width.to_json(),
        "height": b.height.to_json(),
        "absolute_left": b.absolute_left.to_json(),
        "absolute_top": b.absolute_top.to_json(),
      })
    }
    "cursor" => Some(doc.cursor().to_json())
    "page_number" => Some(doc.page_number().to_json())
    "page_count" => Some(doc.page_count().to_json())
    _ => self.graphics(name, args, opts)
  }
}

///|
/// Runs ops in order (a block's).
fn Run::ops(self : Run, ops : Array[Json]) -> Unit raise {
  for op in ops {
    self.op(op)
  }
}

///|
/// The ops of an op's block: its trailing `{"block": [ops]}`.
fn block(args : Array[Json]) -> Array[Json]? {
  match args.last() {
    Some(Object(map)) =>
      match map.get("block") {
        Some(Array(ops)) => Some(ops)
        _ => None
      }
    _ => None
  }
}

///|
/// Runs one op, logging what the driver logs.
fn Run::op(self : Run, op : Json) -> Unit raise {
  guard op is Array(items) && items.length() > 0 else {
    raise ScriptError("not an op: \{op.stringify()}")
  }
  let name = string(items[0])
  let args = items[1:].to_owned()
  if name == "!raises" {
    // [expected, op]: the op runs as any other (a query in it is logged),
    // then the class of the error it raised, or null
    guard args is [expected, Array(_) as inner] else {
      raise ScriptError("!raises needs an expected class and an op")
    }
    let raised = fn(error : @prawn.PrawnError) {
      self.log.push({
        "raises": expected,
        "error": error.ruby_class().to_json(),
      })
    }
    self.op(inner) catch {
      @prawn.CannotFit => {
        raised(@prawn.CannotFit)
        return
      }
      @prawn.IncompatibleStringEncoding(s) => {
        raised(@prawn.IncompatibleStringEncoding(s))
        return
      }
      e => raise e
    }
    self.log.push({ "raises": expected, "error": Json::null() })
  } else if name.has_prefix("?") {
    let query = name[1:].to_owned()
    let shown = args.filter(a => !(a is Object(map) && map.contains("block")))
    let label : Json = if shown.is_empty() {
      query.to_json()
    } else {
      Json::array([query.to_json(), ..shown])
    }
    match self.call(query, args) {
      Some(value) => self.log.push({ "query": label, "value": value })
      None => self.log.push({ "unsupported": query.to_json() })
    }
  } else if self.call(name, args) is None {
    self.log.push({ "unsupported": name.to_json() })
  }
}

///|
fn page_size(j : Json?) -> (Double, Double) raise ScriptError {
  match j {
    None => (612.0, 792.0)
    Some(String(name)) =>
      match @prawn.page_size_named(name) {
        Some(size) => size
        None => raise ScriptError("page size \{name}")
      }
    Some(Array([w, h])) => (number(w), number(h))
    Some(other) => raise ScriptError("page size \{other.stringify()}")
  }
}

///|
fn margin(j : Json?) -> Array[Double] raise ScriptError {
  match j {
    None => [36.0]
    Some(Number(x, ..)) => [x]
    Some(Array(xs)) => xs.map(number)
    Some(other) => raise ScriptError("margin \{other.stringify()}")
  }
}

///|
async fn main {
  let args = @env.args()
  guard args.length() == 4 else {
    @stdio.stderr.write("usage: oracle SCRIPT.json OUT.pdf OUT.jsonl\n")
    fail("bad arguments")
  }
  let script = @json.parse(@fs.read_file(args[1]).text())
  let setup = match script {
    Object(map) =>
      match map.get("document") {
        Some(Object(d)) => d
        _ => Map([])
      }
    _ => Map([])
  }
  let doc = @prawn.Document::new(
    size=page_size(setup.get("page_size")),
    layout=setup.get("page_layout").bind(symbol).unwrap_or("portrait"),
    margin=margin(setup.get("margin")),
  )
  let run = { doc, log: [], }
  guard script is Object(map) && map.get("ops") is Some(Array(ops)) else {
    fail("no ops")
  }
  for op in ops {
    run.op(op) catch {
      ScriptError(message) => fail("\{message} in \{op.stringify()}")
      e => raise e
    }
  }
  @fs.write_file(args[2], doc.render(), create_mode=CreateOrTruncate)
  let log = StringBuilder()
  for entry in run.log {
    log.write_string(entry.stringify())
    log.write_char('\n')
  }
  @fs.write_file(args[3], log.to_string(), create_mode=CreateOrTruncate)
}

///|
fn point(j : Json) -> (Double, Double) raise ScriptError {
  match j {
    Array([x, y]) => (number(x), number(y))
    _ => raise ScriptError("not a point: \{j.stringify()}")
  }
}

///|
/// Control points `{"bounds": [[x1, y1], [x2, y2]]}` of a curve.
fn curve_bounds(
  opts : Map[String, Json],
) -> ((Double, Double), (Double, Double)) raise ScriptError {
  match opts.get("bounds") {
    Some(Array([a, b])) => (point(a), point(b))
    _ => raise ScriptError("a curve needs bounds")
  }
}

///|
/// The points of an op taking them one by one (`polygon`) or flat (`line`
/// with four numbers).
fn points(args : ArrayView[Json]) -> Array[(Double, Double)] raise ScriptError {
  match args {
    [Number(_), ..] => {
      let out = []
      let mut i = 0
      while i + 1 < args.length() {
        out.push((number(args[i]), number(args[i + 1])))
        i = i + 2
      }
      out
    }
    _ => args.map(point)
  }
}

///|
/// Builds shape `name` (Prawn's path-building methods); whether it is one.
fn shape(
  doc : @prawn.Document,
  name : String,
  args : Array[Json],
  opts : Map[String, Json],
) -> Bool raise ScriptError {
  let positional = args.filter(a => !(a is Object(_)))
  match name {
    "move_to" => {
      let p = points(positional[:])[0]
      doc.move_to(p.0, p.1)
    }
    "line_to" => {
      let p = points(positional[:])[0]
      doc.line_to(p.0, p.1)
    }
    "curve_to" => doc.curve_to(point(positional[0]), curve_bounds(opts))
    "curve" =>
      doc.curve(point(positional[0]), point(positional[1]), curve_bounds(opts))
    "rectangle" =>
      doc.rectangle(
        point(positional[0]),
        number(positional[1]),
        number(positional[2]),
      )
    "rounded_rectangle" =>
      doc.rounded_rectangle(
        point(positional[0]),
        number(positional[1]),
        number(positional[2]),
        number(positional[3]),
      )
    "line" => {
      let ps = points(positional[:])
      doc.line(ps[0], ps[1])
    }
    "horizontal_line" =>
      doc.horizontal_line(
        number(positional[0]),
        number(positional[1]),
        at?=opts.get("at").map(number),
      )
    "horizontal_rule" => doc.horizontal_rule()
    "vertical_line" =>
      doc.vertical_line(
        number(positional[0]),
        number(positional[1]),
        at=number(opts.get("at").unwrap_or(Json::null())),
      )
    "circle" => doc.circle(point(positional[0]), number(positional[1]))
    "ellipse" =>
      doc.ellipse(
        point(positional[0]),
        number(positional[1]),
        r2?=positional.get(2).map(number),
      )
    "polygon" => doc.polygon(points(positional[:]))
    "rounded_polygon" =>
      doc.rounded_polygon(number(positional[0]), points(positional[1:]))
    _ => return false
  }
  true
}

///|
/// Runs a graphics op (`graphics.mbt`); its value, or None when it is not
/// one this module runs.
fn Run::graphics(
  self : Run,
  name : String,
  args : Array[Json],
  opts : Map[String, Json],
) -> Json? raise {
  let doc = self.doc
  let even_odd = opts.get("fill_rule").bind(symbol) == Some("even_odd")
  let paint = fn(kind : String) {
    match kind {
      "stroke" => doc.stroke()
      "close_and_stroke" => doc.close_and_stroke()
      "fill" => doc.fill(even_odd~)
      _ => doc.fill_and_stroke(even_odd~)
    }
  }
  match name {
    "fill_color" | "stroke_color" if args is [String(hex)] => {
      guard @prawn.color_of_hex(hex) is Some(color) else { return None }
      if name == "fill_color" {
        doc.set_fill_color(color)
      } else {
        doc.set_stroke_color(color)
      }
    }
    "line_width" if args is [Number(_)] => doc.set_line_width(number(args[0]))
    "cap_style" =>
      doc.set_cap_style(
        match args.get(0).bind(symbol) {
          Some("butt") => ButtCap
          Some("round") => RoundCap
          Some("projecting_square") => SquareCap
          _ => return None
        },
      )
    "join_style" =>
      doc.set_join_style(
        match args.get(0).bind(symbol) {
          Some("miter") => MiterJoin
          Some("round") => RoundJoin
          Some("bevel") => BevelJoin
          _ => return None
        },
      )
    "dash" if only(opts, ["space", "phase"]) => {
      let lengths = match args[0] {
        Array(xs) => xs.map(number)
        x => [number(x)]
      }
      doc.dash(
        lengths,
        space?=opts.get("space").map(number),
        phase=opts.get("phase").map(number).unwrap_or(0.0),
      )
    }
    "undash" => doc.undash()
    "close_path" => doc.close_path()
    "stroke_bounds" => doc.stroke_bounds()
    "stroke" | "close_and_stroke" | "fill" | "fill_and_stroke" if only(opts, [
        "fill_rule",
      ]) => {
      match block(args) {
        Some(ops) => self.ops(ops)
        None => ()
      }
      paint(name)
    }
    _ => {
      // a shape, built (Prawn's path methods) or painted at once
      // (`stroke_rectangle`, `fill_circle`, `fill_and_stroke_polygon`)
      let (kind, shape_name) = if name.has_prefix("fill_and_stroke_") {
        ("fill_and_stroke", name["fill_and_stroke_".length():].to_owned())
      } else if name.has_prefix("stroke_") {
        ("stroke", name["stroke_".length():].to_owned())
      } else if name.has_prefix("fill_") {
        ("fill", name["fill_".length():].to_owned())
      } else {
        ("", name)
      }
      if !shape(doc, shape_name, args, opts) {
        return None
      }
      if kind != "" {
        paint(kind)
      }
    }
  }
  Some(Json::null())
}
