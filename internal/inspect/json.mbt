///|
fn paint_json(p : Paint?) -> Json {
  match p {
    None => Json::null()
    Some(p) =>
      {
        "space": p.space.to_json(),
        "values": p.values.to_json(),
        "alpha": p.alpha.to_json(),
      }
  }
}

///|
fn rect_json(r : Rect?) -> Json {
  match r {
    None => Json::null()
    Some(r) => [r.x0, r.y0, r.x1, r.y1].to_json()
  }
}

///|
/// What the comparison sees on a page, as JSON (for `compare inspect`).
pub fn PageView::to_json(self : PageView) -> Json {
  {
    "width": self.width.to_json(),
    "height": self.height.to_json(),
    "rotate": self.rotate.to_json(),
    "glyphs": Json::array(
      self.glyphs.map(g => {
        "order": g.order.to_json(),
        "text": g.text.to_json(),
        "font": g.font.to_json(),
        "size": g.size.to_json(),
        "matrix": g.matrix.to_json(),
        "x": g.x.to_json(),
        "y": g.y.to_json(),
        "mode": g.mode.to_json(),
        "fill": paint_json(g.fill),
        "stroke": paint_json(g.stroke),
        "pen": g.pen.to_json(),
        "style": g.style,
        "clip": rect_json(g.clip),
        "blend": g.blend.to_json(),
      }),
    ),
    "marks": Json::array(
      self.marks.map(m => {
        "order": m.order.to_json(),
        "kind": m.kind.to_json(),
        "points": m.points.to_json(),
        "lengths": m.lengths.to_json(),
        "paints": Json::array(m.paints.map(p => paint_json(Some(p)))),
        "exact": m.exact,
        "clip": rect_json(m.clip),
        "blend": m.blend.to_json(),
      }),
    ),
  }
}
