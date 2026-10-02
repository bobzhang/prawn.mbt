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
/// The options of an op: its trailing object without `block` (as the driver
/// takes them).
fn options(args : Array[Json]) -> Map[String, Json] {
  match args.last() {
    Some(Object(map)) if !map.contains("trace") => {
      let out = Map([])
      for k, v in map {
        if k != "block" {
          out[k] = v
        }
      }
      out
    }
    _ => Map([])
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
    "cursor" => Some(doc.cursor().to_json())
    "page_number" => Some(doc.page_number().to_json())
    "page_count" => Some(doc.page_count().to_json())
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
    run.op(op)
  }
  @fs.write_file(args[2], doc.render(), create_mode=CreateOrTruncate)
  let log = StringBuilder()
  for entry in run.log {
    log.write_string(entry.stringify())
    log.write_char('\n')
  }
  @fs.write_file(args[3], log.to_string(), create_mode=CreateOrTruncate)
}
