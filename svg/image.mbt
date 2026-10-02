///|
// `<image>` (prawn-svg's `Elements::Image`): a PNG or JPEG, or an SVG
// drawn as a nested document, from a base64 data URL or a file.

///|
/// The dimensions (pixels) and media type of PNG and JPEG data.
pub fn raster_info(data : Bytes) -> (Int, Int, String)? {
  let be32 = fn(o : Int) {
    (data[o].to_int() << 24) |
    (data[o + 1].to_int() << 16) |
    (data[o + 2].to_int() << 8) |
    data[o + 3].to_int()
  }
  let u16 = fn(o : Int) { (data[o].to_int() << 8) | data[o + 1].to_int() }
  if data.length() > 24 &&
    data[0] == b'\x89' &&
    data[1] == b'P' &&
    data[2] == b'N' &&
    data[3] == b'G' {
    return Some((be32(16), be32(20), "image/png"))
  }
  if data.length() > 4 && data[0] == b'\xFF' && data[1] == b'\xD8' {
    let mut i = 2
    while i + 9 < data.length() {
      if data[i] != b'\xFF' {
        i += 1
        continue
      }
      let marker = data[i + 1].to_int()
      let length = u16(i + 2)
      if marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC {
        return Some((u16(i + 7), u16(i + 5), "image/jpeg"))
      }
      i += 2 + length
    }
  }
  None
}

///|
let base64_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Decode base64 leniently (Ruby's `unpack1('m')`): characters outside
/// the alphabet are skipped, decoding stops at padding.
pub fn decode_base64(text : StringView) -> Bytes {
  let buf = Buffer()
  let mut acc = 0
  let mut bits = 0
  for c in text {
    if c == '=' {
      break
    }
    guard base64_alphabet.find(c.to_string()) is Some(v) else { continue }
    acc = (acc << 6) | v
    bits += 6
    if bits >= 8 {
      bits -= 8
      buf.write_byte(((acc >> bits) & 0xFF).to_byte())
    }
  }
  buf.to_bytes()
}

///|
/// Load what an image URL names (prawn-svg's `UrlLoader` as
/// asciidoctor-pdf configures it: data URLs and files, no web requests).
fn Node::load_url(self : Node, url : String) -> Bytes raise Skip {
  let fail = fn(message : String) -> Bytes raise Skip {
    raise SkipWarning("Error retrieving URL \{url}: \{message}")
  }
  if downcase(url.unsafe_substring(start=0, end=@cmp.minimum(5, url.length()))) ==
    "data:" {
    let lower = downcase(url)
    let prefixes = [
      "data:image/png;base64", "data:image/jpeg;base64", "data:image/jpg;base64",
      "data:image/svg+xml;base64",
    ]
    for prefix in prefixes {
      if lower.has_prefix(prefix) {
        // `(;[a-z0-9]+)*,`
        let mut i = prefix.length()
        while i < lower.length() && lower[i] == ';' {
          i += 1
          while i < lower.length() &&
                (
                  (lower[i] >= 'a' && lower[i] <= 'z') ||
                  (lower[i] >= '0' && lower[i] <= '9')
                ) {
            i += 1
          }
        }
        if i < lower.length() && lower[i] == ',' {
          return decode_base64(url[i + 1:])
        }
      }
    }
    return fail(
      "prawn-svg only supports base64-encoded image/png, image/jpeg, and image/svg+xml data URLs",
    )
  }
  let lower = downcase(url)
  // a URL with a scheme other than `file` has no loader
  let scheme = match url.find(":") {
    Some(i) if i > 1 &&
      lower
      .unsafe_substring(start=0, end=i)
      .iter()
      .all(c => {
        (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') ||
        c == '+' ||
        c == '-' ||
        c == '.'
      }) => Some(lower.unsafe_substring(start=0, end=i))
    _ => None
  }
  let path = match scheme {
    None => url
    Some("file") => {
      let rest = url.unsafe_substring(start=5, end=url.length())
      if rest.has_prefix("//") {
        let after = rest.unsafe_substring(start=2, end=rest.length())
        if !after.has_prefix("/") {
          return fail(
            "prawn-svg does not suport file: URLs with a host. Your URL probably doesn't start with three slashes, and it should.",
          )
        }
        after
      } else {
        rest
      }
    }
    Some(_) => return fail("No handler available for this URL scheme")
  }
  let path = percent_decode(path)
  match (self.env().read_file)(path) {
    Some(bytes) => bytes
    None => fail("File \{path} does not exist")
  }
}

///|
fn percent_decode(s : String) -> String {
  guard s.contains("%") else { return s }
  let bytes = Buffer()
  let utf8 = @utf8.encode(s)
  let mut i = 0
  while i < utf8.length() {
    let b = utf8[i]
    if b == b'%' && i + 2 < utf8.length() {
      match
        (
          hex_digit(utf8[i + 1].to_int().to_uint16()),
          hex_digit(utf8[i + 2].to_int().to_uint16()),
        ) {
        (Some(h), Some(l)) => {
          bytes.write_byte((h * 16 + l).to_byte())
          i += 3
          continue
        }
        _ => ()
      }
    }
    bytes.write_byte(b)
    i += 1
  }
  @utf8.decode_lossy(bytes.to_bytes())
}

///|
fn Node::parse_image(self : Node) -> Unit raise Skip {
  self.require_attributes(["width", "height"])
  if self.state.computed.get("display") == Some("none") {
    raise SkipQuietly
  }
  guard self.href() is Some(url) else {
    raise SkipWarning("image tag must have an href or xlink:href")
  }
  let x = self.x_pixels(self.attr("x").unwrap_or("0"))
  let y = self.y_pixels(self.attr("y").unwrap_or("0"))
  let width = self.x_pixels(self.attr("width").unwrap_or("0"))
  let height = self.y_pixels(self.attr("height").unwrap_or("0"))
  let preserve = self.attr("preserveAspectRatio")
  if width == 0.0 || height == 0.0 {
    raise SkipQuietly
  }
  self.require_positive([width, height])
  let data = self.load_url(url)
  let (dimensions, content) = match raster_info(data) {
    Some((w, h, mime)) => ((w.to_double(), h.to_double()), Ok((data, mime)))
    None => {
      let text = @utf8.decode_lossy(data)
      if !text.contains("<svg") {
        raise SkipWarning("Unsupported image type supplied to image tag")
      }
      // an SVG that shows itself (or one that shows it) would be drawn
      // forever
      if self.doc.nesting >= max_nesting {
        raise SkipWarning(
          "SVG images are nested more than \{max_nesting} deep; skipping tag",
        )
      }
      let document = SvgDocument::parse(
        text,
        (width, height),
        width~,
        height~,
        preserve_aspect_ratio?=preserve,
      ) catch {
        _ => raise SkipWarning("Unsupported image type supplied to image tag")
      }
      document.nesting = self.doc.nesting + 1
      document.limits = self.doc.limits
      (
        (document.sizing.output_width, document.sizing.output_height),
        Err(document),
      )
    }
  }
  let aspect = AspectRatio::new(preserve, (width, height), dimensions)
  let calls = []
  if aspect.slice {
    calls.push(Save)
    calls.push(Rectangle(x, y, width, height))
    calls.push(Clip)
  }
  let ix = x + aspect.x
  let iy = y + aspect.y
  match content {
    Ok((bytes, mime)) =>
      calls.push(Image(bytes, mime, ix, iy, aspect.width, aspect.height))
    Err(document) =>
      calls.push(Transform(translate(ix, iy), Some([SubDocument(document)])))
  }
  if aspect.slice {
    calls.push(Restore)
  }
  self.shape = calls
  self.bbox = Some((ix, iy, ix + aspect.width, iy + aspect.height))
}

///|
fn Node::apply_image(self : Node) -> Unit {
  for call in self.shape {
    self.add(call)
  }
}
