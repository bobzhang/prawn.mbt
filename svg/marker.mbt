///|
// Markers on lines, polylines, polygons and paths (prawn-svg's
// `Pathable#apply_markers` and `Elements::Marker#apply_marker`).

///|
fn atan2_degrees(y : Double, x : Double) -> Double {
  @math.atan2(y, x) * 180.0 / @math.PI
}

///|
/// The angle a marker at each command's end point takes: the bisector of
/// the incoming and outgoing directions (prawn-svg's `angles`).
fn marker_angles(commands : Array[PathCommand]) -> Array[Double] {
  let mut last : (Double, Double) = (0, 0)
  let destination_angles : Array[(Double?, Double?)] = []
  let pick = fn(
    base : (Double, Double),
    a : (Double, Double),
    b : (Double, Double),
    c : (Double, Double),
  ) {
    if a != base {
      a
    } else if b != base {
      b
    } else {
      c
    }
  }
  for command in commands {
    let angles = match command {
      Move(_, _) => (None, None)
      Line(x, y) | ClosePath(x, y) => {
        let angle = atan2_degrees(y - last.1, x - last.0)
        (Some(angle), Some(angle))
      }
      Curve(x, y, x1, y1, x2, y2) => {
        let p = pick(last, (x1, y1), (x2, y2), (x, y))
        let start = atan2_degrees(p.1 - last.1, p.0 - last.0)
        let q = pick((x, y), (x2, y2), (x1, y1), last)
        let stop = atan2_degrees(y - q.1, x - q.0)
        (Some(start), Some(stop))
      }
    }
    last = command.destination()
    destination_angles.push(angles)
  }
  let bisect = fn(first : Double, second : Double) {
    let b = (first + second) / 2.0
    if (first - second).abs() > 180.0 {
      if b >= 0.0 {
        b - 180.0
      } else {
        b + 180.0
      }
    } else {
      b
    }
  }
  let angles : Array[Double] = []
  for i in 0..<(destination_angles.length() - 1) {
    let first = destination_angles[i]
    let second = destination_angles[i + 1]
    angles.push(
      match (first.0, second.0) {
        (None, s) => s.unwrap_or(0.0)
        (Some(_), None) => first.1.unwrap_or(0.0)
        (Some(_), Some(_)) =>
          bisect(first.1.unwrap_or(0.0), second.1.unwrap_or(0.0))
      },
    )
  }
  match commands.last() {
    Some(ClosePath(_, _)) => {
      let first = destination_angles[destination_angles.length() - 1].1.unwrap_or(
        0.0,
      )
      let second = angles.get(0).unwrap_or(0.0)
      angles.push(bisect(first, second))
    }
    _ =>
      angles.push(
        destination_angles.last().map(a => a.1.unwrap_or(0.0)).unwrap_or(0.0),
      )
  }
  angles
}

///|
fn Node::apply_markers(self : Node) -> Unit {
  let commands = self.commands
  if commands.is_empty() {
    return
  }
  let angles = marker_angles(commands)
  match self.url_reference(self.properties.get("marker-start"), "marker") {
    Some(marker) =>
      marker.apply_marker(self, commands[0].destination(), angles[0])
    None => ()
  }
  match self.url_reference(self.properties.get("marker-mid"), "marker") {
    Some(marker) =>
      for i in 1..<(commands.length() - 1) {
        marker.apply_marker(self, commands[i].destination(), angles[i])
      }
    None => ()
  }
  match self.url_reference(self.properties.get("marker-end"), "marker") {
    Some(marker) =>
      marker.apply_marker(
        self,
        commands[commands.length() - 1].destination(),
        angles[angles.length() - 1],
      )
    None => ()
  }
}

///|
/// Draw this marker at `point` on `element`, turned by `angle` degrees.
fn Node::apply_marker(
  self : Node,
  element : Node,
  point : (Double, Double),
  angle : Double,
) -> Unit {
  let sizing = Sizing::new(
    (0, 0),
    view_box?=self.attr("viewBox"),
    preserve_aspect_ratio?=self.attr("preserveAspectRatio"),
  ).set_document_size(
    self.attr("markerWidth").unwrap_or("3"),
    self.attr("markerHeight").unwrap_or("3"),
  )
  sizing.calculate()
  if sizing.invalid {
    self.warn("<marker> cannot be rendered due to invalid sizing information")
    return
  }
  // a copy of the marker's calls at every vertex
  if !self.doc.spend(call_count(self.base_calls)) {
    return
  }
  // in the element's top-level calls
  let saved = element.calls
  element.calls = element.base_calls
  element.add(Save)
  element.apply_transform()
  element.apply_opacity()
  element.apply_clip_path()
  element.add(Transform(translate(point.0, point.1), None))
  let angle = match self.attr("orient") {
    Some("auto") => angle
    Some(orient) => ruby_to_f(orient)
    None => 0.0
  }
  let position = element.calls
  if angle != 0.0 {
    // Prawn's `rotate` about the origin, clockwise in y-down terms
    element.enter(Transform(rotation(angle), Some([])))
  }
  if self.attr("markerUnits") != Some("userSpaceOnUse") {
    let s = element.state.stroke_width
    element.add(Transform(scale(s, s), None))
  }
  let ref_x = self.attr("refX").map(v => self.x_pixels(v)).unwrap_or(0.0)
  let ref_y = self.attr("refY").map(v => self.y_pixels(v)).unwrap_or(0.0)
  element.add(
    Transform(translate(-ref_x * sizing.x_scale, -ref_y * sizing.y_scale), None),
  )
  if self.overflow_hidden() {
    element.add(
      Rectangle(
        sizing.x_offset * sizing.x_scale,
        sizing.y_offset * sizing.y_scale,
        sizing.output_width,
        sizing.output_height,
      ),
    )
    element.add(Clip)
  }
  element.add(Transform(scale(sizing.x_scale, sizing.y_scale), None))
  // the marker's content, inside a container whose specified properties
  // are the marker's computed ones (so they are all applied again)
  let state = self.state.dup()
  let container = Node::new(self.doc, Container, None, [], state)
  for name, value in state.computed.map {
    if value != "inherit" {
      container.properties.map[name] = value
    }
  }
  container.parse_and_apply()
  for call in self.base_calls {
    container.add(call.copy())
  }
  for call in container.base_calls {
    element.add(call)
  }
  element.calls = position
  element.add(Restore)
  element.calls = saved
}
