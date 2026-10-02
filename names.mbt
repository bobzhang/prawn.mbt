///|
/// The PDF destination name for an id (asciidoctor-pdf's
/// `derive_anchor_from_id`): the id itself when it is ASCII, else `0x` and
/// the hex of its UTF-8 bytes.
pub fn pdf_anchor_name(id : String) -> String {
  if id.iter().all(c => c.to_int() < 0x80) {
    return id
  }
  let sb = StringBuilder()
  sb.write_string("0x")
  for byte in @utf8.encode(id) {
    let v = byte.to_int()
    sb.write_char("0123456789abcdef"[v >> 4].unsafe_to_char())
    sb.write_char("0123456789abcdef"[v & 15].unsafe_to_char())
  }
  sb.to_string()
}
