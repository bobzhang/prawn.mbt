///|
fn paint_json(p : Paint?) -> Json {
  match p {
    None => Json::null()
    Some(p) =>
      {
        "space": Json(p.space),
        "values": Json(p.values),
        "alpha": Json(p.alpha),
      }
  }
}

///|
fn rect_json(r : Rect?) -> Json {
  match r {
    None => Json::null()
    Some(r) => Json([r.x0, r.y0, r.x1, r.y1])
  }
}

///|
/// What the comparison sees on a page, as JSON (for `compare inspect`).
pub fn PageView::to_json(self : PageView) -> Json {
  {
    "width": Json(self.width),
    "height": Json(self.height),
    "rotate": Json(self.rotate),
    "glyphs": Json::array(
      self.glyphs.map(g => {
        "order": Json(g.order),
        "text": Json(g.text),
        "font": Json(g.font),
        "size": Json(g.size),
        "matrix": Json(g.matrix),
        "x": Json(g.x),
        "y": Json(g.y),
        "mode": Json(g.mode),
        "fill": paint_json(g.fill),
        "stroke": paint_json(g.stroke),
        "pen": Json(g.pen),
        "style": g.style,
        "clip": rect_json(g.clip),
        "blend": Json(g.blend),
      }),
    ),
    "marks": Json::array(
      self.marks.map(m => {
        "order": Json(m.order),
        "kind": Json(m.kind),
        "points": Json(m.points),
        "lengths": Json(m.lengths),
        "paints": Json::array(m.paints.map(p => paint_json(Some(p)))),
        "exact": m.exact,
        "clip": rect_json(m.clip),
        "blend": Json(m.blend),
      }),
    ),
  }
}
