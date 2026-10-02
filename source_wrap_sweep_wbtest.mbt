///|
/// What `source_wrap` makes of a sweep case, as the sweep shows Ruby's
/// printed lines: `|` between lines, no-break spaces as `~`, the highlight
/// mark as `^`, trailing spaces dropped; `CannotFit` when it cannot fit.
fn sweep_result(
  width : Double,
  start : Int,
  lines : Array[String],
  highlight : Int,
) -> String raise {
  let courier = { ..mono_style(), family: "Courier", }
  let builtin = { catalog: FontCatalog::load([]), hooks: Hooks::new(), }
  let pad = (start + lines.length() - 1).to_string().length()
  let fragments : Array[Fragment] = []
  for i, text in lines {
    let n = (start + i).to_string()
    fragments.push({
      text: "\u{a0}".repeat(pad - n.length()) + n + " ",
      style: { ..courier, linenum: true, },
      anchor: None,
    })
    if highlight == i {
      fragments.push({
        text: "\u{200B}",
        style: {
          ..courier,
          background: Some(@pagelayout.Color::rgb(255, 255, 204)),
          code_background: Some(FullLine),
          line_mark: true,
        },
        anchor: None,
      })
    }
    if text != "" {
      fragments.push({ text, style: courier, anchor: None, })
    }
    if i < lines.length() - 1 {
      fragments.push({ text: "\n", style: courier, anchor: None, })
    }
  }
  match source_wrap(fragments, builtin, width) {
    None => "CannotFit"
    Some(wrapped) =>
      wrapped
      .map(f => f.text)
      .join("")
      .replace_all(old="\u{a0}", new="~")
      .replace_all(old="\u{200B}", new="^")
      .split("\n")
      .map(l => l.trim_end(chars=" ").to_owned())
      .collect()
      .join("|")
  }
}

///|
test "the rest of a broken number on a line of its own is progress" {
  // 10pt Courier at 13pt: "12" breaks off, "3 " fits but "3 a" does not;
  // the number's rest takes a line, then the blank (four characters wide,
  // as the first number) breaks too and lets the text through
  inspect(sweep_result(13.0, 123, ["a"], -1), content="12|3|~|a")
  // the mark goes with the text, not with the number's rest
  inspect(sweep_result(13.0, 123, ["a"], 0), content="12|3|~|^a")
  // a blank alone, the text never fitting beside it: Ruby prints blanks
  // until the box is full, the port cannot fit
  inspect(sweep_result(12.0, 1, ["a"], -1), content="CannotFit")
}

///|
test "a mark before an indent goes with the text, the indent stripped" {
  // Ruby strips the mark (a NUL) with the blanks at the end of the line,
  // and the mark takes no room, so the next line strips the indent
  inspect(sweep_result(24.0, 1, ["  ab"], 0), content="1|~ ^ab")
  inspect(sweep_result(24.0, 1, ["  ab"], -1), content="1|~ ab")
}

///|
/// The differential sweep: every case against Ruby's SourceWrap. Where
/// Ruby never finishes (`LEFT`: it prints blanks until the box is full,
/// a blank and the glyph after it never fitting together), the port must
/// fail instead.
test "source_wrap agrees with Ruby's SourceWrap across the sweep" {
  let diffs = []
  for c in sweep_cases {
    let (width, start, lines, highlight, ruby) = c
    let got = sweep_result(width, start, lines, highlight)
    let ok = if ruby == "LEFT" { got == "CannotFit" } else { got == ruby }
    if !ok {
      diffs.push(
        "\{width} \{start} [\{lines.join("/")}] hl=\{highlight}: Ruby \{ruby}, port \{got}",
      )
    }
  }
  if !diffs.is_empty() {
    println(diffs.join("\n"))
    fail("\{diffs.length()} of \{sweep_cases.length()} cases differ")
  }
}
