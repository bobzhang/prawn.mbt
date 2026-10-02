///|
/// A text context whose `mono` family is pagelayout's Liberation Mono (each
/// glyph 0.6 em wide), so the tests need no font files.
fn mono_text() -> TextContext raise {
  let files = []
  for bold in [false, true] {
    files.push(
      (
        "mono",
        bold,
        false,
        @fontoutlines.outline_sfnt("Liberation Mono", bold~, italic=false).unwrap(),
      ),
    )
  }
  { catalog: FontCatalog::load(files), hooks: Hooks::new(base_family="mono"), }
}

///|
/// A 10pt style in `mono`.
fn mono_style() -> Style {
  {
    family: "mono",
    size: 10.0,
    bold: false,
    italic: false,
    color: @pagelayout.Color::rgb(0, 0, 0),
    link: None,
    background: None,
    script: 0,
    border_offset: 0.0,
    underline: false,
    strike: false,
    wj: false,
    image: -1,
    callback: -1,
    doc_bold: false,
    doc_italic: false,
    font_set: false,
    text_transform: None,
    code_background: None,
    linenum: false,
    line_mark: false,
  }
}

///|
/// The texts of `fragments`, no-break spaces shown as `~`, zero-width
/// spaces (line marks) as `^`.
fn texts(fragments : Array[Fragment]) -> String {
  fragments
  .map(f => {
    f.text
    .replace_all(old="\u{a0}", new="~")
    .replace_all(old="\u{200b}", new="^")
    .escape()
  })
  .join(" | ")
}

///|
test "a numbered line that wraps continues behind a blank as wide as its number" {
  let style = mono_style()
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "x".repeat(30) + " " + "y".repeat(30), style, anchor: None, },
  ]
  // 25 glyphs a line: the number, then 23 x; the rest of the x behind the
  // blank (a word too long for the line after a number wraps by
  // character, SourceLineWrap), then the y, as wide
  inspect(
    texts(source_wrap(fragments, mono_text(), 150.0).unwrap()),
    content=(
      #|"1 " | "xxxxxxxxxxxxxxxxxxxxxxx" | "\n" | "~ " | "xxxxxxx " | "\n" | "~ " | "yyyyyyyyyyyyyyyyyyyyyyy" | "\n" | "~ " | "yyyyyyy"
    ),
  )
}

///|
test "a highlighted line keeps its mark where it wraps" {
  let style = mono_style()
  let mark : Fragment = {
    text: "\u{200B}",
    style: {
      ..style,
      background: Some(@pagelayout.Color::rgb(255, 255, 204)),
      code_background: Some(Gap(3.8, true)),
      line_mark: true,
    },
    anchor: None,
  }
  let fragments : Array[Fragment] = [
    {
      text: "~1 ".replace_all(old="~", new="\u{a0}"),
      style: { ..style, linenum: true, },
      anchor: None,
    },
    mark,
    { text: "a".repeat(40), style, anchor: None, },
  ]
  inspect(
    texts(source_wrap(fragments, mono_text(), 150.0).unwrap()),
    content=(
      #|"~1 " | "^" | "aaaaaaaaaaaaaaaaaaaaaa" | "\n" | "~  " | "^" | "aaaaaaaaaaaaaaaaaa"
    ),
  )
}

///|
test "a numbered line where no text fits cannot fit" {
  // Prawn raises CannotFit; this used to insert blanks forever
  let style = mono_style()
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "x", style, anchor: None, },
  ]
  inspect(source_wrap(fragments, mono_text(), 5.0) is None, content="true")
}

///|
test "unnumbered fragments are left as they are" {
  let fragments : Array[Fragment] = [
    { text: "x".repeat(60), style: mono_style(), anchor: None, },
  ]
  inspect(
    source_wrap(fragments, mono_text(), 150.0)
    .map(f => f.length())
    .unwrap_or(-1),
    content="1",
  )
}
