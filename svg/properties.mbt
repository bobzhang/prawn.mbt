///|
// The CSS properties prawn-svg understands (its `Properties`): what an
// element specifies (from stylesheets, its `style` attribute and its
// presentation attributes, in that order, later ones winning) and what it
// computes to by inheritance.

///|
priv struct PropertyConfig {
  default : String
  inheritable : Bool
  keywords : Array[String]
  restricted : Bool
}

///|
let property_configs : Map[String, PropertyConfig] = {
  let c = fn(default, inheritable, keywords, restricted) -> PropertyConfig {
    { default, inheritable, keywords, restricted, }
  }
  Map::from_array([
    ("clip-path", c("none", false, ["inherit", "none"], false)),
    ("color", c("", true, [], false)),
    ("display", c("inline", false, ["inherit", "inline", "none"], true)),
    ("fill", c("black", true, ["inherit", "none", "currentColor"], false)),
    ("fill-opacity", c("1", true, [], false)),
    ("fill-rule", c("nonzero", true, ["inherit", "nonzero", "evenodd"], false)),
    ("font-family", c("sans-serif", true, [], false)),
    (
      "font-size",
      c(
        "medium",
        true,
        [
          "inherit", "xx-small", "x-small", "small", "medium", "large", "x-large",
          "xx-large", "larger", "smaller",
        ],
        false,
      ),
    ),
    (
      "font-style",
      c("normal", true, ["inherit", "normal", "italic", "oblique"], true),
    ),
    (
      "font-variant",
      c("normal", true, ["inherit", "normal", "small-caps"], true),
    ),
    (
      "font-weight",
      c(
        "normal",
        true,
        [
          "inherit", "normal", "bold", "100", "200", "300", "400", "500", "600",
          "700", "800", "900",
        ],
        true,
      ),
    ),
    ("letter-spacing", c("normal", true, ["inherit", "normal"], false)),
    ("marker-end", c("none", true, ["inherit", "none"], false)),
    ("marker-mid", c("none", true, ["inherit", "none"], false)),
    ("marker-start", c("none", true, ["inherit", "none"], false)),
    ("opacity", c("1", false, [], false)),
    (
      "overflow",
      c(
        "visible",
        false,
        ["inherit", "visible", "hidden", "scroll", "auto"],
        true,
      ),
    ),
    (
      "stop-color",
      c("black", false, ["inherit", "none", "currentColor"], false),
    ),
    ("stroke", c("none", true, ["inherit", "none", "currentColor"], false)),
    ("stroke-dasharray", c("none", true, ["inherit", "none"], false)),
    (
      "stroke-linecap",
      c("butt", true, ["inherit", "butt", "round", "square"], true),
    ),
    (
      "stroke-linejoin",
      c("miter", true, ["inherit", "miter", "round", "bevel"], true),
    ),
    ("stroke-opacity", c("1", true, [], false)),
    ("stroke-width", c("1", true, [], false)),
    (
      "text-anchor",
      c("start", true, ["inherit", "start", "middle", "end"], true),
    ),
    ("text-decoration", c("none", true, ["inherit", "none", "underline"], true)),
    ("dominant-baseline", c("auto", true, ["inherit", "auto", "middle"], true)),
  ])
}

///|
/// Property values by name.
priv struct Properties {
  map : Map[String, String]
}

///|
fn Properties::new() -> Properties {
  { map: Map([]), }
}

///|
/// The initial values (prawn-svg's default stylesheet).
fn Properties::defaults() -> Properties {
  let map = Map([])
  for name, config in property_configs {
    map[name] = config.default
  }
  { map, }
}

///|
fn Properties::get(self : Properties, name : String) -> String? {
  self.map.get(name)
}

///|
fn Properties::copy(self : Properties) -> Properties {
  { map: self.map.copy(), }
}

///|
/// prawn-svg's `Properties#set`: a known property takes the value, a
/// keyword in lower case; an unknown word for a keyword-restricted
/// property is its default. False for names that are not properties.
fn Properties::set(self : Properties, name : String, value : String) -> Bool {
  let key = downcase(name)
  guard property_configs.get(key) is Some(config) else { return false }
  let value = strip(value)
  let keyword = downcase(value)
  let keywords = if config.keywords.is_empty() {
    ["inherit"]
  } else {
    config.keywords
  }
  // `currentColor` is listed in its own case, so only it matches as such
  let v = if keywords.contains(keyword) {
    keyword
  } else if keywords.contains(value) {
    value
  } else if config.restricted {
    config.default
  } else {
    value
  }
  self.map[key] = v
  true
}

///|
let font_sizes : Map[String, Double] = {
  "xx-small": 4.0,
  "x-small": 8.0,
  "small": 12.0,
  "medium": 16.0,
  "large": 20.0,
  "x-large": 24.0,
  "xx-large": 28.0,
}

///|
/// The font size in points (`numerical_font_size`).
fn Properties::font_size(self : Properties) -> Double {
  let v = self.get("font-size").unwrap_or("medium")
  match font_sizes.get(v) {
    Some(size) => size
    None => ruby_to_f(v)
  }
}

///|
/// prawn-svg's `compute_properties`: take what `specified` sets (the font
/// size relative to the inherited one); a non-inheritable property it does
/// not set goes back to its default.
fn Properties::compute(self : Properties, specified : Properties) -> Unit {
  for name, config in property_configs {
    match specified.get(name) {
      Some(value) if value != "inherit" => {
        let v = if name == "font-size" {
          let size = self.font_size()
          let computed = if value.has_suffix("%") {
            size * (ruby_to_f(value) / 100.0)
          } else if value == "larger" {
            size + 4.0
          } else if value == "smaller" {
            size - 4.0
          } else if ends_with_unit(value, "rem") {
            ruby_to_f(value) * 16.0
          } else if ends_with_unit(value, "em") {
            size * ruby_to_f(value)
          } else {
            match font_sizes.get(value) {
              Some(s) => s
              None => ruby_to_f(value)
            }
          }
          computed.to_string()
        } else {
          value
        }
        self.map[name] = v
      }
      Some(_) => ()
      None => if !config.inheritable { self.map[name] = config.default }
    }
  }
}

///|
/// Whether `value` ends in `unit` right after a digit or a dot,
/// case-insensitively.
fn ends_with_unit(value : String, unit : String) -> Bool {
  let lower = downcase(value)
  let n = lower.length()
  let u = unit.length()
  n > u &&
  lower.has_suffix(unit) &&
  (
    (lower[n - u - 1] >= '0' && lower[n - u - 1] <= '9') ||
    lower[n - u - 1] == '.'
  )
}
