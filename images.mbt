///|
// Prawn's `image` (`images.rb`): a PNG or JPEG file placed at a point, or
// in the flow of the page (at the position, moving it down, to the next
// page when it does not fit), sized as given or by its pixels as points.
// pagelayout embeds the file (pdflite reads it).

///|
/// What Prawn knows of an image: its type and its size in pixels (Prawn's
/// `Prawn::Images::PNG` / `JPG`).
pub(all) struct ImageInfo {
  /// "png" or "jpeg"
  kind : String
  width : Int
  height : Int
}

///|
/// Where an image goes across the bounds, in the flow (Prawn's
/// `:position`).
pub(all) enum ImagePosition {
  ImageLeft
  ImageCenter
  ImageRight
  /// this far from the bounds' left
  ImageAt(Double)
}

///|
/// Where an image goes down the bounds (Prawn's `:vposition`): by default
/// at the position, in the flow of the page.
pub(all) enum ImageVPosition {
  ImageTop
  ImageMiddle
  ImageBottom
  /// this far below the bounds' top
  ImageDown(Double)
}

///|
fn be16(data : Bytes, at : Int) -> Int {
  (data[at].to_int() << 8) | data[at + 1].to_int()
}

///|
fn be32(data : Bytes, at : Int) -> Int {
  (be16(data, at) << 16) | be16(data, at + 2)
}

///|
/// What Prawn knows of the image in `data` (from `file`), checked as Prawn
/// checks it (UnsupportedImageType) and as far as pdflite can embed it
/// faithfully (Unsupported otherwise, rather than drawing it wrongly or
/// not at all).
fn read_image(file : String, data : Bytes) -> ImageInfo raise PrawnError {
  let n = data.length()
  let png_signature = b"\x89PNG\r\n\x1a\n"
  if n >= 8 && data[0:8] == png_signature[:] {
    // the IHDR chunk: size, bit depth, colour type, compression, filter,
    // interlace
    if n < 33 {
      raise UnsupportedImageType("the PNG \{file} is truncated")
    }
    let colour_type = data[25].to_int()
    if data[26] != b'\x00' {
      raise UnsupportedImageType("PNG uses an unsupported compression method")
    }
    if data[27] != b'\x00' {
      raise UnsupportedImageType("PNG uses an unsupported filter method")
    }
    if data[28] != b'\x00' {
      raise UnsupportedImageType("PNG uses unsupported interlace method")
    }
    if ![0, 2, 3, 4, 6].contains(colour_type) {
      raise UnsupportedImageType("PNG uses an unsupported number of colors")
    }
    // embedded as rendering will, its data inflated (a corrupt one
    // refused now, before the position moves)
    try
      @pdflite.pdf_image_object_of_png_data(
        @pdflite.pdf_document_empty(),
        data[:],
      )
    catch {
      _ => raise Unsupported("the image \{file} (a PNG pdflite cannot read)")
    } noraise {
      _ => ()
    }
    return { kind: "png", width: be32(data, 16), height: be32(data, 20), }
  }
  // JPEG: markers up to a start of frame (SOF0–SOF15 but DHT, JPG, DAC)
  guard n >= 4 && data[0] == b'\xFF' && data[1] == b'\xD8' else {
    raise UnsupportedImageType("image file is an unrecognised format")
  }
  let mut i = 2
  // whether Adobe's marker (APP14) has come: Adobe writes CMYK inverted
  let mut adobe = false
  while i + 9 < n {
    if data[i] != b'\xFF' {
      i += 1
      continue
    }
    let marker = data[i + 1].to_int()
    if marker == 0xFF {
      i += 1
      continue
    }
    if marker == 0xEE &&
      be16(data, i + 2) >= 14 &&
      data[i + 4:i + 9] == b"Adobe" {
      adobe = true
    }
    if marker >= 0xC0 &&
      marker <= 0xCF &&
      marker != 0xC4 &&
      marker != 0xC8 &&
      marker != 0xCC {
      // Prawn inverts every CMYK JPEG; pdflite, Adobe's (which are the
      // inverted ones). Another would be drawn in other colours than
      // Prawn's.
      if data[i + 9] == b'\x04' && !adobe {
        raise Unsupported(
          "the image \{file} (a CMYK JPEG without Adobe's marker)",
        )
      }
      // embedded as rendering will (one pdflite cannot embed refused now)
      try @pdflite.pdf_image_object_of_jpeg_data(data[:]) catch {
        _ => raise Unsupported("the image \{file} (a JPEG pdflite cannot read)")
      } noraise {
        _ => ()
      }
      return {
        kind: "jpeg",
        height: be16(data, i + 5),
        width: be16(data, i + 7),
      }
    }
    i += 2 + be16(data, i + 2)
  }
  raise UnsupportedImageType("the JPEG \{file} has no frame")
}

///|
/// Prawn's `calc_image_dimensions`: the size an image is drawn at, in
/// points.
fn ImageInfo::dimensions(
  self : ImageInfo,
  width : Double?,
  height : Double?,
  scale : Double?,
  fit : (Double, Double)?,
) -> (Double, Double) {
  let iw = self.width.to_double()
  let ih = self.height.to_double()
  // in Prawn's order: a width or a height alone, then a scale, then a fit
  // (with both a width and a height given too), then as given
  match (width, height, scale, fit) {
    (Some(w), None, _, _) => (iw * (w / iw), ih * (w / iw))
    (None, Some(h), _, _) => (iw * (h / ih), ih * (h / ih))
    (_, _, Some(s), _) => (iw * s, ih * s)
    (_, _, None, Some((bw, bh))) => {
      let bp = bw / bh
      let ip = iw / ih
      if ip > bp {
        (bw, bw / ip)
      } else {
        (bh * ip, bh)
      }
    }
    (w, h, _, _) => (w.unwrap_or(iw), h.unwrap_or(ih))
  }
}

///|
/// Prawn's `image`: the image in `file` (read through the document's
/// assets) drawn with its top left at `at` (a point of the bounds), or,
/// without `at`, in the flow of the page at `position` across the bounds
/// and `vposition` down them (by default at the position, which moves down
/// past it, to the next page when it does not fit); `width` and `height`
/// (either keeps the proportions), `scale` or `fit` size it, else its
/// pixels are points. What Prawn knows of it is returned.
pub fn Document::image(
  self : Document,
  file : String,
  at? : (Double, Double),
  width? : Double,
  height? : Double,
  scale? : Double,
  fit? : (Double, Double),
  position? : ImagePosition = ImageLeft,
  vposition? : ImageVPosition,
) -> ImageInfo raise PrawnError {
  guard (self.assets)(file) is Some(data) else {
    raise ArgumentError("\{file} not found")
  }
  let info = read_image(file, data)
  let (w, h) = info.dimensions(width, height, scale, fit)
  let (x, y) = match at {
    // a point of the bounds (Prawn's `map_to_absolute`)
    Some((ax, ay)) => {
      let b = self.bounds()
      (b.absolute_left + ax, b.absolute_top - b.height + ay)
    }
    None => {
      let (x, y) = self.image_position(w, h, position, vposition)
      self.move_text_position(h)
      (x, y)
    }
  }
  self.page().items.push(
    Image({
      x_pt: x,
      y_pt: self.page_h() - y,
      w_pt: w,
      h_pt: h,
      data,
      mime: if info.kind == "png" {
        "image/png"
      } else {
        "image/jpeg"
      },
    }),
  )
  info
}

///|
/// Prawn's `image_position`: where an image `width` by `height` placed in
/// the flow has its top left, on the page.
fn Document::image_position(
  self : Document,
  width : Double,
  height : Double,
  position : ImagePosition,
  vposition : ImageVPosition?,
) -> (Double, Double) {
  let box = self.bbox
  let top = box.top
  let bounds_height = box.height_at(self.y())
  let y = match vposition {
    Some(ImageTop) => top
    Some(ImageMiddle) => top - (bounds_height - height) / 2.0
    Some(ImageBottom) => top - bounds_height + height
    Some(ImageDown(down)) => top - down
    None => {
      // Prawn's `determine_y_with_page_flow`: past the bottom of the
      // reference bounds (the nearest fixed box), on to the next column or
      // page
      if self.y() - height < self.reference_bottom() {
        self.move_past_bottom()
      }
      self.y()
    }
  }
  // across the bounds as they are now (a page break may have moved them)
  let (side, bounds_width) = self.bbox.side()
  let x = match position {
    ImageLeft => side
    ImageCenter => side + (bounds_width - width) / 2.0
    ImageRight => self.bbox.right_side() - width
    ImageAt(dx) => side + dx
  }
  (x, y)
}

///|
/// The bottom of Prawn's `reference_bounds`: of the current box, or of the
/// nearest fixed box it is in when it is stretchy.
fn Document::reference_bottom(self : Document) -> Double {
  let mut box = self.bbox
  while box.height is None {
    match box.parent {
      Some(parent) => box = parent
      None => break
    }
  }
  box.top - box.height_at(self.y())
}

///|
/// Prawn's `move_text_position`: down by `amount`, past the bottom of the
/// bounds (of the margin box, in a stretchy box) on to the next column or
/// page first when it does not fit.
fn Document::move_text_position(self : Document, amount : Double) -> Unit {
  let bottom = if self.bbox.height is None {
    self.margin.top - self.margin.height_at(self.y())
  } else {
    self.bbox.top - self.bbox.height_at(self.y())
  }
  if self.y() - amount < bottom {
    self.move_past_bottom()
  }
  self.set_y(self.y() - amount)
}
