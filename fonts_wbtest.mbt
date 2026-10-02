///|
test "legends: raw glyphs, and the escapes of prawn-icon fi.yml" {
  let legend = parse_flat_yaml(
    "---\nfi:\n  __font_version__: '3.0'\n  address-book: \"\\uf100\"\n  alert: \"\u{f101}\"\n  plain: x\n",
  )
  inspect(legend.get("address-book") == Some("\u{f100}"), content="true")
  inspect(legend.get("alert") == Some("\u{f101}"), content="true")
  inspect(legend.get("plain") == Some("x"), content="true")
  inspect(legend.contains("__font_version__"), content="false")
}
