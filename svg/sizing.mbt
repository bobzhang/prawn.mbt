///|
// prawn-svg's DocumentSizing and AspectRatio calculators, with
// asciidoctor-pdf's patch that reads a `width` or `height` in `px` at
// 0.75 pt per pixel (prawn-svg itself takes pixels as points).

///|
/// A preserveAspectRatio fit of an object into a container: the size the
/// object is drawn at and its offset within the container.
pub struct AspectRatio {
  width : Double
  height : Double
  x : Double
  y : Double
  slice : Bool
}

///|
/// prawn-svg's `AspectRatio`.
pub fn AspectRatio::new(
  value : String?,
  container : (Double, Double),
  object : (Double, Double),
) -> AspectRatio {
  let words = value
    .unwrap_or("xMidYMid meet")
    .split(" ")
    .filter(w => w != "")
    .map(w => w.to_owned())
    .collect()
  let mut index = 0
  if words.length() > 0 && words[0] == "defer" {
    index = 1
  }
  let align = words.get(index)
  let slice = words.get(index + 1) == Some("slice")
  let (wc, hc) = container
  let (wo, ho) = object
  let container_ratio = wc / hc
  let object_ratio = wo / ho
  if align == Some("none") {
    return { width: wc, height: hc, x: 0, y: 0, slice, }
  }
  // xMinYMid and the like, case-insensitively; anything else is centred
  let (ax, ay) = match align.map(a => downcase(strip(a))) {
    Some(a) if a.length() == 8 && a.has_prefix("x") && a[4] == 'y' => {
      let xs = a.unsafe_substring(start=1, end=4)
      let ys = a.unsafe_substring(start=5, end=8)
      let ok = fn(s : String) { s == "min" || s == "mid" || s == "max" }
      if ok(xs) && ok(ys) {
        (xs, ys)
      } else {
        ("mid", "mid")
      }
    }
    _ => ("mid", "mid")
  }
  if (container_ratio > object_ratio) == slice {
    let height = wc / object_ratio
    let y = match ay {
      "min" => 0.0
      "mid" => (hc - wc / object_ratio) / 2.0
      _ => hc - wc / object_ratio
    }
    { width: wc, height, x: 0, y, slice, }
  } else {
    let width = hc * object_ratio
    let x = match ax {
      "min" => 0.0
      "mid" => (wc - hc * object_ratio) / 2.0
      _ => wc - hc * object_ratio
    }
    { width, height: hc, x, y: 0, slice, }
  }
}

///|
/// A `width` or `height` attribute as the sizing reads it: a string for
/// `to_pixels`, or (in `px`, asciidoctor-pdf's patch) points already.
priv enum Length {
  Raw(String)
  Points(Double)
}

///|
fn length_of(value : String?) -> Length? {
  match value {
    None => None
    Some(v) if v.has_suffix("px") => Some(Points(ruby_to_f(v) * 0.75))
    Some(v) => Some(Raw(v))
  }
}

///|
/// The size and scale of an SVG viewport (prawn-svg's DocumentSizing):
/// `output_width` by `output_height` points, the user space scaled by
/// `x_scale`, `y_scale` and offset by `x_offset`, `y_offset`.
pub struct Sizing {
  bounds : (Double, Double)
  priv document_width : Length?
  priv document_height : Length?
  priv view_box : String?
  priv preserve_aspect_ratio : String
  mut requested_width : Double?
  mut requested_height : Double?
  mut x_offset : Double
  mut y_offset : Double
  mut x_scale : Double
  mut y_scale : Double
  mut viewport_width : Double
  mut viewport_height : Double
  mut viewport_diagonal : Double
  mut output_width : Double
  mut output_height : Double
  mut invalid : Bool
}

///|
/// A sizing for a viewport element (`width`, `height`, `viewBox` and
/// `preserveAspectRatio` attributes) inside `bounds`; `calculate` it
/// before use.
pub fn Sizing::new(
  bounds : (Double, Double),
  width? : String,
  height? : String,
  view_box? : String,
  preserve_aspect_ratio? : String,
) -> Sizing {
  {
    bounds,
    document_width: length_of(width),
    document_height: length_of(height),
    view_box,
    preserve_aspect_ratio: preserve_aspect_ratio.unwrap_or("xMidYMid meet"),
    requested_width: None,
    requested_height: None,
    x_offset: 0,
    y_offset: 0,
    x_scale: 1,
    y_scale: 1,
    viewport_width: 0,
    viewport_height: 0,
    viewport_diagonal: 0,
    output_width: 0,
    output_height: 0,
    invalid: true,
  }
}

///|
/// Override the size the attributes give (a marker's `markerWidth`).
fn Sizing::set_document_size(
  self : Sizing,
  width : String,
  height : String,
) -> Sizing {
  {
    ..self,
    document_width: Some(Raw(width)),
    document_height: Some(Raw(height)),
  }
}

///|
/// prawn-svg's `DocumentSizing#calculate`.
pub fn Sizing::calculate(self : Sizing) -> Unit {
  self.x_offset = 0
  self.y_offset = 0
  self.x_scale = 1
  self.y_scale = 1
  let container_width = self.requested_width.unwrap_or(self.bounds.0)
  let container_height = self.requested_height.unwrap_or(self.bounds.1)
  let pixels = fn(
    length : Length?,
    requested : Double?,
    axis : Double,
  ) -> Double? {
    match length {
      Some(Points(p)) => Some(p)
      Some(Raw(s)) => Some(to_pixels(s, axis))
      None => requested
    }
  }
  let mut output_width = pixels(
    self.document_width,
    self.requested_width,
    container_width,
  )
  let mut output_height = pixels(
    self.document_height,
    self.requested_height,
    container_height,
  )
  match self.view_box {
    Some(view_box) => {
      let values = split_comma_wsp(strip(view_box)).map(ruby_to_f)
      let value = fn(i : Int) { values.get(i).unwrap_or(0.0) }
      self.x_offset = value(0)
      self.y_offset = value(1)
      self.viewport_width = value(2)
      self.viewport_height = value(3)
      let vw = self.viewport_width
      let vh = self.viewport_height
      if vw > 0 && vh > 0 {
        if output_width is None && output_height is None {
          output_width = Some(container_width)
        }
        let ow = match output_width {
          Some(w) => w
          None => output_height.unwrap_or(0) * vw / vh
        }
        let oh = match output_height {
          Some(h) => h
          None => ow * vh / vw
        }
        output_width = Some(ow)
        output_height = Some(oh)
        let aspect = AspectRatio::new(
          Some(self.preserve_aspect_ratio),
          (ow, oh),
          (vw, vh),
        )
        self.x_scale = aspect.width / vw
        self.y_scale = aspect.height / vh
        self.x_offset -= aspect.x / self.x_scale
        self.y_offset -= aspect.y / self.y_scale
      }
    }
    None => {
      let ow = output_width.unwrap_or(container_width)
      let oh = output_height.unwrap_or(container_height)
      output_width = Some(ow)
      output_height = Some(oh)
      self.viewport_width = ow
      self.viewport_height = oh
    }
  }
  self.output_width = output_width.unwrap_or(0)
  self.output_height = output_height.unwrap_or(0)
  self.invalid = output_width is None ||
    output_height is None ||
    self.viewport_width <= 0 ||
    self.viewport_height <= 0 ||
    self.output_width <= 0 ||
    self.output_height <= 0 ||
    self.requested_width.map_or(false, w => w <= 0) ||
    self.requested_height.map_or(false, h => h <= 0)
  if self.invalid {
    return
  }
  self.viewport_diagonal = (self.viewport_width * self.viewport_width +
    self.viewport_height * self.viewport_height).sqrt() /
    (2.0 : Double).sqrt()
  match (self.requested_width, self.requested_height) {
    (Some(w), _) => {
      let scale = w / self.output_width
      self.output_width = w
      self.output_height *= scale
      self.x_scale *= scale
      self.y_scale *= scale
    }
    (None, Some(h)) => {
      let scale = h / self.output_height
      self.output_height = h
      self.output_width *= scale
      self.x_scale *= scale
      self.y_scale *= scale
    }
    (None, None) => ()
  }
}

///|
/// prawn-svg's `Interface#resize`: recalculate for a requested width or
/// height.
pub fn Sizing::resize(self : Sizing, width? : Double, height? : Double) -> Unit {
  self.requested_width = width
  self.requested_height = height
  self.calculate()
}
