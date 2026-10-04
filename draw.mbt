///|
// Drawing a set line, as Prawn's `Text::Formatted::Box#draw_fragment` does:
// each fragment the line holds in turn (one with nothing to show on the
// line too), in its own font and colour (`begin_fragment`), what its
// callbacks put behind it, its text (or what the `draw_text_callback`
// draws instead), then its underline and strikethrough, its links and
// what its callbacks put in front.

///|
/// Draw `line` on the current page: its left edge at `x0`, its baseline at
/// `baseline` (in Flow's page coordinates, y down).
fn Document::ink_line(
  self : Document,
  line : Line,
  x0 : Double,
  baseline : Double,
) -> Unit {
  if !line.runs.is_empty() {
    self.flow.mark_inked()
  }
  let page = self.page()
  for held in line.held {
    let (fragment, x, style, face) = held
    let runs = line.runs.filter(r => r.fragment == fragment)
    let x = x0 +
      (match runs.get(0) {
        Some(r) => r.x
        None => x
      })
    let mut width = 0.0
    let text = StringBuilder()
    for run in runs {
      width += run.width
      text.write_string(run.text)
    }
    page.items.append(
      self.draw_fragment(
        runs,
        x0,
        x,
        width,
        baseline,
        style,
        face,
        text.to_string(),
      ),
    )
  }
}

///|
/// Prawn's `draw_fragment`: a fragment's items, from its runs on the line
/// (`x0` their line's left edge); it starts at `x`, `width` wide, its text
/// `text`.
fn Document::draw_fragment(
  self : Document,
  runs : Array[LineRun],
  x0 : Double,
  x : Double,
  width : Double,
  baseline : Double,
  style : Style,
  face : Face,
  text : String,
) -> Array[@pagelayout.PageItem] {
  // the fragment's font and colour, to its end
  self.begin_fragment(style)
  let out = self.underlays(x, width, baseline, style, face, text)
  let rise = script_rise(style, face)
  match self.draw_text_callback {
    Some(draw) =>
      // called with the fragment's text where it starts (Prawn's default
      // kerning); a dry run draws nothing
      if !self.dry_run {
        let box = self.current_box()
        let at = (
          x - box.left,
          self.flow.page_h() - (baseline - rise) - box.bottom_at(self.y()),
        )
        out.append(self.capture(() => draw(text, at, true)))
      }
    None => {
      let (bold, italic) = style.face_style()
      let font = self.flow.model.add_font({
        family: style.family,
        bold,
        italic,
      })
      // in the fill colour current now: the fragment's own, or what a
      // callback set
      let color = self.gs().fill
      for run in runs {
        out.push(
          Text({
            font,
            size_pt: style.size,
            x_pt: x0 + run.x,
            baseline_pt: baseline - rise,
            text: run.text,
            advances_pt: run.advances,
            color,
          }),
        )
      }
    }
  }
  out.append(self.decorations(x, width, baseline, style, face, text))
  self.end_fragment()
  out
}

///|
/// How far a sub- or superscript's baseline is raised (Prawn's arranger
/// sets a superscript 0.85 of its ascender up, a subscript its descender
/// down).
fn script_rise(style : Style, face : Face) -> Double {
  match style.script {
    1 => 0.85 * face.ascender_pt(style.size)
    -1 => -face.descender_pt(style.size)
    _ => 0.0
  }
}
