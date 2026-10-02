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
    wrap_break: false,
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
test "a bordered fragment wraps where its padding still fits" {
  // 12 + 5 + 12 + 5 = 34 > 30: the break falls on the padding after the
  // x; after the first x both lines take 12 + 5 + 6 + 5 = 28
  let style = mono_style()
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "xx", style: { ..style, border_offset: 5.0, }, anchor: None, },
  ]
  inspect(
    texts(source_wrap(fragments, mono_text(), 30.0).unwrap()),
    content=(
      #|"1 " | "x" | "\n" | "~ " | "x"
    ),
  )
  // at a blank when there is one: 12 + 5 + 24 + 5 = 46 > 44
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "ab c", style: { ..style, border_offset: 5.0, }, anchor: None, },
  ]
  inspect(
    texts(source_wrap(fragments, mono_text(), 44.0).unwrap()),
    content=(
      #|"1 " | "ab " | "\n" | "~ " | "c"
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
test "a line number wider than the line breaks before its blank" {
  let style = mono_style()
  let number = (n : String) => {
    ({ text: n, style: { ..style, linenum: true, }, anchor: None, } : Fragment)
  }
  let newline : Fragment = { text: "\n", style, anchor: None, }
  let fragments = [number("1 "), newline, number("2 "), newline]
  // not even a digit fits: Prawn's CannotFit
  inspect(source_wrap(fragments, mono_text(), 5.0) is None, content="true")
  // the digit fits, its blank does not: as asciidoctor-pdf prints
  // "1\n\n2\n", the line's text (here none) on a line of its own
  inspect(
    texts(source_wrap(fragments, mono_text(), 6.0).unwrap()),
    content=(
      #|"1" | "\n" | "\n" | "2" | "\n" | "\n"
    ),
  )
  inspect(
    texts(source_wrap(fragments, mono_text(), 50.0).unwrap()),
    content=(
      #|"1 " | "\n" | "2 " | "\n"
    ),
  )
  // text after it goes on the next line, as Ruby's "1", "a"
  let fragments = [number("1 "), { text: "a", style, anchor: None, }]
  inspect(
    texts(source_wrap(fragments, mono_text(), 8.0).unwrap()),
    content=(
      #|"1" | "\n" | "a"
    ),
  )
  // and where that text wraps, its blank (as wide as the first number)
  // breaks the same way: Ruby's "1", "a", " ", "b", " ", "c"
  let fragments = [number("1 "), { text: "abc", style, anchor: None, }]
  inspect(
    texts(source_wrap(fragments, mono_text(), 8.0).unwrap()),
    content=(
      #|"1" | "\n" | "a" | "\n" | "~" | "\n" | "b" | "\n" | "~" | "\n" | "c"
    ),
  )
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

///|
test "a wrapped highlighted line paints both its lines, in Courier too" {
  // 40 x in 150pt: the line wraps once, its mark goes with it, so each
  // line is painted from the number's end to the edge
  let courier = { ..mono_style(), family: "Courier", }
  let builtin = { catalog: FontCatalog::load([]), hooks: Hooks::new(), }
  let line = highlighted_line(courier)
  line[2] = { ..line[2], text: "x".repeat(40), }
  let wrapped = source_wrap(line, builtin, 150.0).unwrap()
  inspect(
    texts(wrapped),
    content=(
      #|"1 " | "^" | "xxxxxxxxxxxxxxxxxxxxxxx" | "\n" | "~ " | "^" | "xxxxxxxxxxxxxxxxx"
    ),
  )
  inspect(
    rectangles(builtin, wrapped),
    content="22+138 255,255,204; 22+138 255,255,204",
  )
}

///|
test "a highlighted line keeps its mark where its number breaks" {
  // 8pt: the number breaks before its blank, then a, b and c each go on a
  // line of their own, behind a blank that breaks the same way; as in
  // Ruby, the lines of a, b and c are highlighted, not the number's or the
  // blanks'
  let line = highlighted_line(mono_style())
  line[2] = { ..line[2], text: "abc", }
  let wrapped = source_wrap(line, mono_text(), 8.0).unwrap()
  inspect(
    texts(wrapped),
    content=(
      #|"1" | "\n" | "^" | "a" | "\n" | "~" | "\n" | "^" | "b" | "\n" | "~" | "\n" | "^" | "c"
    ),
  )
  inspect(
    rectangles(mono_text(), wrapped),
    content="10+150 255,255,204; 10+150 255,255,204; 10+150 255,255,204",
  )
}

///|
test "text wider than the line after a broken number cannot fit" {
  // Helvetica: 1 is 5.56pt, W 9.44pt, i 2.22pt; the number breaks before
  // its blank at 6pt, then W alone does not fit (Prawn's CannotFit)
  let helvetica = { ..mono_style(), family: "Helvetica", }
  let builtin = { catalog: FontCatalog::load([]), hooks: Hooks::new(), }
  let line = (text : String) => {
    [
      { text: "1 ", style: { ..helvetica, linenum: true, }, anchor: None, },
      { text, style: helvetica, anchor: None, },
    ]
  }
  inspect(source_wrap(line("W"), builtin, 6.0) is None, content="true")
  inspect(
    texts(source_wrap(line("i"), builtin, 6.0).unwrap()),
    content=(
      #|"1" | "\n" | "i"
    ),
  )
  // a 10pt number, a 20pt x (12pt) at 8pt
  let style = mono_style()
  let fragments : Array[Fragment] = [
    { text: "1 ", style: { ..style, linenum: true, }, anchor: None, },
    { text: "x", style: { ..style, size: 20.0, }, anchor: None, },
  ]
  inspect(source_wrap(fragments, mono_text(), 8.0) is None, content="true")
}

///|
test "a number whose digits are wider than the line wraps by digit" {
  // 10pt Courier, 6pt a digit, at 8pt: Ruby's SourceWrap prints "1", "2",
  // "a", nothing left over
  let courier = { ..mono_style(), family: "Courier", }
  let builtin = { catalog: FontCatalog::load([]), hooks: Hooks::new(), }
  let fragments : Array[Fragment] = [
    { text: "12 ", style: { ..courier, linenum: true, }, anchor: None, },
    { text: "a", style: courier, anchor: None, },
  ]
  inspect(
    texts(source_wrap(fragments, builtin, 8.0).unwrap()),
    content=(
      #|"1" | "\n" | "2" | "\n" | "a"
    ),
  )
  // not even one digit: CannotFit
  inspect(source_wrap(fragments, builtin, 5.0) is None, content="true")
}

///|
test "a highlighted line paints its background behind its images" {
  // an inline image (drawn as a blue rectangle here) on a highlighted line:
  // the highlight first, so that it does not cover the image
  let base = mono_text()
  let hooks = {
    ..base.hooks,
    image_size: (_, _, _) => (12.0, 8.0, false),
    image_items: (_, _, x, top, w, h) => {
      [rect_item(x, top, w, h, fill=@pagelayout.Color::rgb(0, 0, 255))]
    },
  }
  let text = { ..base, hooks, }
  let line = highlighted_line(mono_style())
  line.push({
    text: "\u{2063}",
    style: { ..mono_style(), image: 0, },
    anchor: None,
  })
  inspect(rectangles(text, line), content="22+138 255,255,204; 28+12 0,0,255")
}
