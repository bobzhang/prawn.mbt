///|
// Drawing a set line, as Prawn's `Text::Formatted::Box#draw_fragment` does:
// each fragment the line holds in turn (one with nothing to show on the
// line too), in its own font and colour (`begin_fragment`), what its
// callbacks put behind it, its text (or what the `draw_text_callback`
// draws instead), then its underline and strikethrough, its links and
// what its callbacks put in front. Each goes on the page current when it
// is drawn, which a callback may change.

///|
/// Draw `line`: its left edge at `left`, its baseline at `baseline`, in
/// the coordinates of the bounds.
fn Document::ink_line(
  self : Document,
  line : Line,
  left : Double,
  baseline : Double,
) -> Unit {
  for held in line.held {
    let (fragment, x, style, face) = held
    let runs = line.runs.filter(r => r.fragment == fragment)
    let x = match runs.get(0) {
      Some(r) => r.x
      None => x
    }
    let mut width = 0.0
    let text = StringBuilder()
    for run in runs {
      width += run.width
      text.write_string(run.text)
    }
    self.draw_fragment(
      runs,
      left + x,
      x,
      width,
      baseline,
      style,
      face,
      text.to_string(),
    )
  }
}

///|
/// Prawn's `draw_fragment`: a fragment from its runs on the line, starting
/// at `left` (`x` into the line), its baseline at `baseline` (both in the
/// coordinates of the bounds), `width` wide, its text `text`.
fn Document::draw_fragment(
  self : Document,
  runs : Array[LineRun],
  left : Double,
  x : Double,
  width : Double,
  baseline : Double,
  style : Style,
  face : Face,
  text : String,
) -> Unit {
  // the fragment's font and colour, to its end
  self.begin_fragment(style)
  // where it is on the page current at each step (pagelayout's page
  // coordinates): a callback may start another
  let on_page = fn() {
    let box = self.current_box()
    (box.left + left, self.page_h() - baseline - box.bottom_at(self.y()))
  }
  // its callbacks (none in a dry run), which see it placed as it starts
  let callbacks = match self.fragment_meta.get(style.callback) {
    Some(meta) if !self.dry_run => meta.callbacks
    _ => []
  }
  let placed = placed_fragment(left, width, baseline, style, face, text)
  for callback in callbacks {
    match callback.render_behind {
      Some(f) => f(placed)
      None => ()
    }
  }
  let rise = script_rise(style, face)
  match self.draw_text_callback {
    Some(draw) =>
      // called with the fragment's text where it starts (Prawn's default
      // kerning); a dry run draws nothing
      if !self.dry_run {
        draw(text, (left, baseline + rise), true)
      }
    None => {
      let (bold, italic) = style.face_style()
      let font = self.model.add_font({ family: style.family, bold, italic, })
      // in the fill colour current now: the fragment's own, or what a
      // callback set
      let color = self.gs().fill
      let items = self.page().items
      let (x_now, baseline_now) = on_page()
      for run in runs {
        items.push(
          Text({
            font,
            size_pt: style.size,
            x_pt: x_now + (run.x - x),
            baseline_pt: baseline_now - rise,
            text: run.text,
            advances_pt: run.advances,
            color,
          }),
        )
      }
    }
  }
  let (x_now, baseline_now) = on_page()
  self.draw_overlays(x_now, width, baseline_now - rise, style, face)
  for callback in callbacks {
    match callback.render_in_front {
      Some(f) => f(placed)
      None => ()
    }
  }
  self.end_fragment()
}

///|
/// Prawn's `draw_fragment_overlay_styles`, link and anchor: the underline
/// and strikethrough, stroked as `stroke_line` strokes them in the current
/// stroke colour and line style, 1.25 points below the baseline (`base`,
/// where a sub- or superscript sits) and 0.3 of the ascender above it;
/// then the URI's annotation and the destination's, as wide as the
/// fragment.
fn Document::draw_overlays(
  self : Document,
  x : Double,
  width : Double,
  base : Double,
  style : Style,
  face : Face,
) -> Unit {
  let a = face.ascender_pt(style.size)
  let d = face.descender_pt(style.size)
  let gs = self.gs()
  let items = self.page().items
  let line = fn(y : Double) -> @pagelayout.PageItem {
    Graphic({
      x_pt: 0.0,
      y_pt: 0.0,
      ops: [
        Path({
          segments: [MoveTo(x, y), LineTo(x + width, y)],
          fill: None,
          fill_rule: NonZero,
          stroke: Some(Solid(gs.stroke)),
          stroke_style: {
            width: if gs.line_width == 0.0 {
              Hairline
            } else {
              Width(gs.line_width)
            },
            cap: gs.cap,
            join: gs.join,
            miter_limit: 10.0,
            dash: gs.dash.copy(),
            dash_phase: gs.dash_phase,
          },
        }),
      ],
    })
  }
  if style.underline {
    items.push(line(base + 1.25))
  }
  if style.strike {
    items.push(line(base - a * 0.3))
  }
  let link = fn(target) {
    items.push(
      Link({ x_pt: x, y_pt: base - a, w_pt: width, h_pt: a + d, target, }),
    )
  }
  match style.link {
    Some(target) => link(target)
    None => ()
  }
  match self.fragment_meta.get(style.callback) {
    Some({ anchor: Some(name), .. }) => link(Named(name))
    _ => ()
  }
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
