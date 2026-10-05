///|
/// A JPEG's markers up to its frame, of four components: Adobe's marker
/// when `adobe`, then a baseline frame of 16 by 16.
fn cmyk_jpeg_for_test(adobe : Bool) -> Bytes {
  let bytes : Array[Int] = [0xFF, 0xD8]
  if adobe {
    bytes.append([
      0xFF, 0xEE, 0x00, 0x0E, 0x41, 0x64, 0x6F, 0x62, 0x65, 0x00, 0x64, 0x00, 0x00,
      0x00, 0x00, 0x00,
    ])
  }
  bytes.append([
    0xFF, 0xC0, 0x00, 0x14, 0x08, 0x00, 0x10, 0x00, 0x10, 0x04, 0x01, 0x11, 0x00,
    0x02, 0x11, 0x00, 0x03, 0x11, 0x00, 0x04, 0x11, 0x00, 0xFF, 0xD9,
  ])
  Bytes::from_array(bytes.map(b => b.to_byte()))
}

///|
test "a CMYK JPEG is embedded when it is Adobe's" {
  // Prawn inverts every CMYK JPEG, pdflite those with Adobe's marker (the
  // inverted ones): only those are drawn as Prawn draws them
  let info = read_image("adobe.jpg", cmyk_jpeg_for_test(true))
  assert_eq((info.kind, info.width, info.height), ("jpeg", 16, 16))
  let refused = try read_image("plain.jpg", cmyk_jpeg_for_test(false)) catch {
    Unsupported(what) => what
    _ => "another error"
  } noraise {
    _ => "embedded"
  }
  assert_eq(refused, "the image plain.jpg (a CMYK JPEG without Adobe's marker)")
}
