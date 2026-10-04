///|
/// The widths of the lines `text` sets 100 points wide in Helvetica 12.
fn line_widths(text : String, paragraphs : Bool) -> Array[Double] raise {
  let ctx = { catalog: FontCatalog::load([]), hooks: Hooks::new(), }
  let style = { ..mono_style(), family: "Helvetica", size: 12.0, }
  typeset_lines([{ text, style, anchor: None, }], ctx, 100.0, Left, paragraphs~).map(line => {
      line.fit_width
    },
  )
}

///|
test "spaces before a line break stay, unless it ends a paragraph" {
  // Prawn keeps them: `omit_trailing_whitespace_from_line_width` stops at
  // the break ("a" is 6.672 wide, a space 3.336)
  assert_eq(line_widths("a  \nb  ", false), [13.344, 6.672])
  // set paragraph by paragraph (`indent_paragraphs`), each ends its text
  assert_eq(line_widths("a  \nb  ", true), [6.672, 6.672])
}
