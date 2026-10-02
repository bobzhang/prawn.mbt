///|
/// The `name(args)` calls of a transform list, as prawn-svg scans them
/// (`\s*(\w+)\(([^)]+)\)\s*`), with the arguments split on commas and
/// whitespace.
fn css_method_calls(text : String) -> Array[(String, Array[String])] {
  let out = []
  let n = text.length()
  let word = fn(c : UInt16) {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '_'
  }
  let mut i = 0
  while i < n {
    // find a word followed directly by `(`, then a non-empty `...)`
    if !word(text[i]) {
      i += 1
      continue
    }
    let start = i
    while i < n && word(text[i]) {
      i += 1
    }
    if i < n && text[i] == '(' {
      match find_from(text, ")", i + 1) {
        Some(close) if close > i + 1 => {
          let name = text.unsafe_substring(start~, end=i)
          let args = strip(text.unsafe_substring(start=i + 1, end=close))
          let parts = []
          // split on /\s*[,\s]\s*/
          let mut field = StringBuilder()
          let mut k = 0
          while k < args.length() {
            let c = args[k]
            if c == ',' || is_ws(c) {
              let mut j = k
              while j < args.length() && is_ws(args[j]) {
                j += 1
              }
              if j < args.length() && args[j] == ',' {
                j += 1
              }
              while j < args.length() && is_ws(args[j]) {
                j += 1
              }
              parts.push(field.to_string())
              field = StringBuilder()
              k = j
            } else {
              field.write_char(c.unsafe_to_char())
              k += 1
            }
          }
          parts.push(field.to_string())
          out.push((name, parts))
          i = close + 1
        }
        _ => ()
      }
    }
  }
  out
}

///|
/// prawn-svg's `parse_transform_attribute`, in y-down user space; lengths
/// are plain numbers. Unsupported transforms are warned about and skipped.
fn parse_transform(
  text : String,
  warnings : Array[String],
) -> @pagelayout.Matrix {
  let mut m = @pagelayout.identity
  for call in css_method_calls(text) {
    let (name, args) = call
    let arg = fn(i : Int) { args.get(i).map(ruby_to_f).unwrap_or(0.0) }
    match name {
      "translate" => m = m.after(translate(arg(0), arg(1)))
      "translateX" => m = m.after(translate(arg(0), 0))
      "translateY" => m = m.after(translate(0, arg(0)))
      "rotate" =>
        match args.length() {
          1 => m = m.after(rotation(arg(0)))
          3 =>
            m = m
              .after(translate(arg(1), arg(2)))
              .after(rotation(arg(0)))
              .after(translate(-arg(1), -arg(2)))
          _ =>
            warnings.push(
              "transform 'rotate' must have either one or three arguments",
            )
        }
      "scale" => {
        let x = arg(0)
        let y = if args.length() > 1 { arg(1) } else { x }
        m = m.after(scale(x, y))
      }
      "skewX" => {
        let t = @math.tan(arg(0) * @math.PI / 180.0)
        m = m.after({ a: 1, b: 0, c: t, d: 1, e: 0, f: 0, })
      }
      "skewY" => {
        let t = @math.tan(arg(0) * @math.PI / 180.0)
        m = m.after({ a: 1, b: t, c: 0, d: 1, e: 0, f: 0, })
      }
      "matrix" =>
        if args.length() != 6 {
          warnings.push("transform 'matrix' must have six arguments")
        } else {
          m = m.after({
            a: arg(0),
            b: arg(1),
            c: arg(2),
            d: arg(3),
            e: arg(4),
            f: arg(5),
          })
        }
      _ =>
        warnings.push("Unknown/unsupported transformation '\{name}'; ignoring")
    }
  }
  m
}
