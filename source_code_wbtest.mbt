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

///|
test "a bordered fragment that does not fit cannot fit, without looping" {
  // the break used to fall on the fragment's padding, which put all of it
  // back on the next line, again and again
  let style = mono_style()
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "x", style: { ..style, border_offset: 5.0, }, anchor: None, },
  ]
  inspect(source_wrap(fragments, mono_text(), 24.0) is None, content="true")
  // with room for it after the number, it is set as it is
  inspect(
    texts(source_wrap(fragments, mono_text(), 40.0).unwrap()),
    content=(
      #|"1 " | "x"
    ),
  )
}

///|
test "a wrapped line keeps the line break that ends it" {
  let style = mono_style()
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "a".repeat(23) + " \n", style, anchor: None, },
    { text: "2 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "b", style, anchor: None, },
  ]
  // the a fill the line, the blank after them wraps (to nothing, Prawn's
  // lstrip), and the line break stays: a blank line, not "~ 2 b"
  inspect(
    texts(source_wrap(fragments, mono_text(), 150.0).unwrap()),
    content=(
      #|"1 " | "aaaaaaaaaaaaaaaaaaaaaaa" | "\n" | "~ " | "\n" | "2 " | "b"
    ),
  )
  // a word that wraps keeps its line break after its rest
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "a".repeat(25) + "\n", style, anchor: None, },
    { text: "2 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "b", style, anchor: None, },
  ]
  inspect(
    texts(source_wrap(fragments, mono_text(), 150.0).unwrap()),
    content=(
      #|"1 " | "aaaaaaaaaaaaaaaaaaaaaaa" | "\n" | "~ " | "aa\n" | "2 " | "b"
    ),
  )
}

///|
test "line numbers wider than the line cannot fit" {
  let style = mono_style()
  let number = (n : String) => {
    ({ text: n, style: { ..style, linenum: true, }, anchor: None, } : Fragment)
  }
  let newline : Fragment = { text: "\n", style, anchor: None, }
  let fragments = [number("1 "), newline, number("2 "), newline]
  inspect(source_wrap(fragments, mono_text(), 5.0) is None, content="true")
  inspect(source_wrap(fragments, mono_text(), 50.0) is Some(_), content="true")
}

///|
test "the blank of a wrapped line has no style of its own" {
  let style = mono_style()
  let numbered = {
    ..style,
    linenum: true,
    bold: true,
    background: Some(@pagelayout.Color::rgb(0x76, 0x6D, 0xAF)),
  }
  let fragments : Array[Fragment] = [
    { text: "1 ", style: numbered, anchor: None, },
    { text: "x".repeat(40), style, anchor: None, },
  ]
  let wrapped = source_wrap(fragments, mono_text(), 150.0).unwrap()
  let blank = wrapped[3]
  inspect(texts([blank]), content="\"~ \"")
  assert_true(blank.style.linenum)
  assert_false(blank.style.bold)
  assert_true(blank.style.background is None)
}

///|
/// The filled rectangles `fragments` draw when typeset at 10pt in a flow
/// 150pt wide from x 10: x, width and colour (as `r,g,b`).
fn rectangles(text : TextContext, fragments : Array[Fragment]) -> String {
  let setup = {
    width: 170.0,
    height: 400.0,
    margin_top: 10.0,
    margin_right: 10.0,
    margin_bottom: 10.0,
    margin_left: 10.0,
  }
  let flow = Flow::new(text.catalog, setup, hooks=text.hooks)
  flow.start_new_page()
  let style = fragments[0].style
  flow.typeset(fragments, line_metrics(1.2, flow.font(style), 10.0), style)
  flow
  .items()
  .filter_map(item => {
    match item {
      Rect({ x_pt, w_pt, fill: Some(c), .. }) =>
        Some("\{x_pt.to_int()}+\{w_pt.to_int()} \{c.r},\{c.g},\{c.b}")
      _ => None
    }
  })
  .join("; ")
}

///|
/// A highlighted line: its number, its mark, its text.
fn highlighted_line(style : Style) -> Array[Fragment] {
  [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    {
      text: "\u{200B}",
      style: {
        ..style,
        background: Some(@pagelayout.Color::rgb(255, 255, 204)),
        code_background: Some(Gap(3.8, true)),
        line_mark: true,
      },
      anchor: None,
    },
    { text: "x", style, anchor: None, },
  ]
}

///|
test "a highlighted line paints its background from its mark to the edge" {
  // from the end of the number (2 glyphs of 6pt) to the right edge
  inspect(
    rectangles(mono_text(), highlighted_line(mono_style())),
    content="22+138 255,255,204",
  )
  // in a built-in font too, where the text is WinAnsi: the mark is no text
  let courier = { ..mono_style(), family: "Courier", }
  let builtin = { catalog: FontCatalog::load([]), hooks: Hooks::new(), }
  inspect(
    rectangles(builtin, highlighted_line(courier)),
    content="22+138 255,255,204",
  )
}
