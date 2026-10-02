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
      // a line break of the source (struck, to tell it from those
      // source_wrap adds)
      fragments.push({
        text: "\n",
        style: { ..courier, strike: true, },
        anchor: None,
      })
    }
  }
  match source_wrap(fragments, builtin, width) {
    None => "CannotFit"
    Some(wrapped) => {
      // the lines as Prawn prints them: a line that wraps or ends the text
      // loses its trailing blanks and mark (Ruby's rstrip of the NUL), one
      // that a line break of the source ends keeps its mark
      let lines = []
      let line = StringBuilder()
      let end_line = (hard : Bool) => {
        let mut s = line
          .to_string()
          .replace_all(old="\u{a0}", new="~")
          .replace_all(old="\u{200B}", new="^")
        s = s.trim_end(chars=if hard { " " } else { " ^" }).to_owned()
        lines.push(s)
        line.reset()
      }
      for f in wrapped {
        let parts = f.text.split("\n").collect()
        for k, part in parts {
          if k > 0 {
            end_line(f.style.strike)
          }
          line.write_view(part)
        }
      }
      end_line(false)
      let text = lines.join("|")
      if highlight < 0 {
        text
      } else {
        "\{text} @ \{highlight_spots(builtin, courier, width, wrapped)}"
      }
    }
  }
}

///|
/// Where the highlight of `fragments` (a highlighted source line, wrapped)
/// is painted when they are typeset `width` wide: `line:x` for each line
/// with a highlight, x from the line's left edge, as Ruby's highlight
/// callback is called.
fn highlight_spots(
  text : TextContext,
  style : Style,
  width : Double,
  fragments : Array[Fragment],
) -> String {
  let setup = {
    width: width + 20.0,
    height: 100000.0,
    margin_top: 10.0,
    margin_right: 10.0,
    margin_bottom: 10.0,
    margin_left: 10.0,
  }
  let fills = (fragments : Array[Fragment]) => {
    let flow = Flow::new(text.catalog, setup, hooks=text.hooks)
    flow.start_new_page()
    let face = flow.font(style)
    flow.typeset(fragments, line_metrics(1.0, face, style.size), style)
    let rects = flow
      .items()
      .filter_map(item => {
        match item {
          Rect({ x_pt, y_pt, fill: Some(c), .. }) if c.b == 204 =>
            Some((x_pt - 10.0, y_pt))
          _ => None
        }
      })
    (rects, face.height_pt(style.size))
  }
  // the first line's highlight, for where the lines are
  let first = fills([
      { text: "1", style: { ..style, linenum: true, }, anchor: None, },
      {
        text: "\u{200B}",
        style: {
          ..style,
          background: Some(@pagelayout.Color::rgb(255, 255, 204)),
          code_background: Some(FullLine),
          line_mark: true,
        },
        anchor: None,
      },
    ]).0[0].1
  let (rects, pitch) = fills(fragments)
  rects
  .map(r => {
    let line = ((r.1 - first) / pitch).round().to_int()
    let x = (r.0 * 100.0).round() / 100.0
    let shown = if x == x.floor() {
      x.to_int().to_string()
    } else {
      x.to_string()
    }
    "\{line}:\{shown}"
  })
  .join(",")
}

///|
test "the rest of a broken number on a line of its own is progress" {
  // 10pt Courier at 13pt: "12" breaks off, "3 " fits but "3 a" does not;
  // the number's rest takes a line, then the blank (four characters wide,
  // as the first number) breaks too and lets the text through
  inspect(sweep_result(13.0, 123, ["a"], -1), content="12|3|~|a")
  // highlighted: the mark ends the number's line, which paints from the
  // end of "3" (the blank after it trimmed, and the mark's NUL with it in
  // Ruby's text), and the text's line has the mark again
  inspect(sweep_result(13.0, 123, ["a"], 0), content="12|3|~|^a @ 1:6,3:0")
  // a blank alone, the text never fitting beside it: Ruby prints blanks
  // until the box is full, the port cannot fit
  inspect(sweep_result(12.0, 1, ["a"], -1), content="CannotFit")
}

///|
test "a mark before an indent paints from the number, the indent stripped" {
  // the indent wraps: the number's line keeps the mark (painted from the
  // end of "1"), and the next line, which strips the indent (the mark
  // takes no room), has it again behind the blank
  inspect(sweep_result(24.0, 1, ["  ab"], 0), content="1|~ ^ab @ 0:6,1:12")
  inspect(sweep_result(24.0, 1, ["  ab"], -1), content="1|~ ab")
}

///|
test "an empty or blank highlighted line paints from its number's end" {
  // Ruby trims the number to "1" (its blank and the mark's NUL are white
  // space at the end of the text) and paints from x 6, not 12
  inspect(sweep_result(150.0, 1, [""], 0), content="1 @ 0:6")
  inspect(sweep_result(150.0, 1, ["   "], 0), content="1 @ 0:6")
  // a line break keeps the blank: Prawn trims no line a break ends
  inspect(sweep_result(150.0, 1, ["", "x"], 0), content="1 ^|2 x @ 0:12")
}

///|
/// The differential sweep: every case against Ruby's SourceWrap. Where
/// Ruby never finishes (`LEFT`: it prints blanks until the box is full,
/// a blank and the glyph after it never fitting together), the port must
/// fail instead; where Ruby fails on a block no document makes (`Error`:
/// a last line with nothing after its number), anything goes.
test "source_wrap agrees with Ruby's SourceWrap across the sweep" {
  let diffs = []
  for c in sweep_cases {
    let (width, start, lines, highlight, ruby) = c
    if ruby == "Error" {
      continue
    }
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
