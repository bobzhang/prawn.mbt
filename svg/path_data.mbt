///|
// SVG path data as prawn-svg reads it (`Elements::Path#parse`): commands
// with their parameters, relative ones made absolute, smooth and
// quadratic curves turned cubic, arcs approximated by cubic curves
// (spaceroots.org's algorithm). Parsing stops at the first command it
// cannot read, keeping what came before.

///|
priv enum PathCommand {
  Move(Double, Double)
  Line(Double, Double)
  /// end point, then the two control points
  Curve(Double, Double, Double, Double, Double, Double)
  /// closes back to the subpath's start, which it records
  ClosePath(Double, Double)
}

///|
fn PathCommand::destination(self : PathCommand) -> (Double, Double) {
  match self {
    Move(x, y) | Line(x, y) | ClosePath(x, y) => (x, y)
    Curve(x, y, _, _, _, _) => (x, y)
  }
}

///|
priv struct PathScanner {
  text : String
  mut pos : Int
}

///|
fn PathScanner::skip(self : PathScanner, comma : Bool) -> Unit {
  while self.pos < self.text.length() {
    let c = self.text[self.pos]
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' || (comma && c == ',') {
      self.pos += 1
    } else {
      break
    }
  }
}

///|
/// A number (`[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?`, the exponent only
/// right after a digit) after optional separators; None, consuming
/// nothing, when there is none.
fn PathScanner::number(self : PathScanner) -> Double? {
  let start = self.pos
  self.skip(true)
  let s = self.text
  let n = s.length()
  let digit = fn(i : Int) { i < n && s[i] >= '0' && s[i] <= '9' }
  let begin = self.pos
  let mut i = self.pos
  if i < n && (s[i] == '+' || s[i] == '-') {
    i += 1
  }
  if digit(i) {
    while digit(i) {
      i += 1
    }
    if i < n && s[i] == '.' {
      i += 1
      while digit(i) {
        i += 1
      }
    }
  } else if i < n && s[i] == '.' && digit(i + 1) {
    i += 1
    while digit(i) {
      i += 1
    }
  } else {
    self.pos = start
    return None
  }
  if digit(i - 1) && i < n && (s[i] == 'e' || s[i] == 'E') {
    let mut j = i + 1
    if j < n && (s[j] == '+' || s[j] == '-') {
      j += 1
    }
    if digit(j) {
      while digit(j) {
        j += 1
      }
      i = j
    }
  }
  self.pos = i
  Some(ruby_to_f(s.unsafe_substring(start=begin, end=i)))
}

///|
/// An arc flag: `0` or `1` after optional separators.
fn PathScanner::flag(self : PathScanner) -> Double? {
  let start = self.pos
  self.skip(true)
  if self.pos < self.text.length() &&
    (self.text[self.pos] == '0' || self.text[self.pos] == '1') {
    self.pos += 1
    Some(if self.text[self.pos - 1] == '1' { 1.0 } else { 0.0 })
  } else {
    self.pos = start
    None
  }
}

///|
/// The parameter groups of a command's parameter string, `count` values
/// each (arcs: flags at the fourth and fifth); None when the string does
/// not divide into whole groups.
fn parameter_groups(params : String, command : Char) -> Array[Array[Double]]? {
  let scanner = PathScanner::{ text: params, pos: 0, }
  let shape : Array[Bool] = match command {
    'A' => [false, false, false, true, true, false, false]
    'C' => [false, false, false, false, false, false]
    'H' | 'V' => [false]
    'L' | 'M' | 'T' => [false, false]
    'Q' | 'S' => [false, false, false, false]
    _ => []
  }
  let groups = []
  if shape.is_empty() {
    // Z: its (empty) pattern matches once per remaining character run,
    // which only happens with nothing left
    return if params == "" { Some([]) } else { None }
  }
  while scanner.pos < params.length() {
    let group = []
    for is_flag in shape {
      let v = if is_flag { scanner.flag() } else { scanner.number() }
      match v {
        Some(v) => group.push(v)
        None => return None
      }
    }
    groups.push(group)
  }
  Some(groups)
}

///|
/// Split path data into commands and their parameter strings
/// (`COMMAND_REGEXP`); None when any part does not fit.
fn split_commands(data : String) -> Array[(Char, String)]? {
  let scanner = PathScanner::{ text: data, pos: 0, }
  let out = []
  let n = data.length()
  while scanner.pos < n {
    scanner.skip(false)
    if scanner.pos >= n {
      break
    }
    let c = data[scanner.pos]
    guard (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') else { return None }
    scanner.pos += 1
    let start = scanner.pos
    while scanner.number() is Some(_) {

    }
    let params = data.unsafe_substring(start~, end=scanner.pos)
    scanner.skip(false)
    out.push((c.unsafe_to_char(), params))
  }
  Some(out)
}

///|
/// prawn-svg's path parser; None for data it rejects altogether ("Invalid/
/// unsupported syntax for SVG path data").
fn parse_path_data(data : String) -> Array[PathCommand]? {
  // trailing whitespace is dropped first
  let mut end = data.length()
  while end > 0 &&
        (
          data[end - 1] == ' ' ||
          data[end - 1] == '\t' ||
          data[end - 1] == '\r' ||
          data[end - 1] == '\n'
        ) {
    end -= 1
  }
  guard split_commands(data.unsafe_substring(start=0, end~)) is Some(commands) else {
    return None
  }
  let path = PathParser::{
    commands: [],
    last: None,
    subpath_start: None,
    previous_control: None,
    previous_quadratic: None,
  }
  for command in commands {
    let (letter, params) = command
    let upper = if letter >= 'a' && letter <= 'z' {
      (letter.to_int() - 32).unsafe_to_char()
    } else {
      letter
    }
    guard "ACHLMQSTVZ".contains_char(upper) else { break }
    guard parameter_groups(params, upper) is Some(groups) else { break }
    if groups.is_empty() && upper != 'Z' {
      break
    }
    path.command(upper, letter != upper, groups)
  }
  Some(path.commands)
}

///|
priv struct PathParser {
  commands : Array[PathCommand]
  mut last : (Double, Double)?
  mut subpath_start : (Double, Double)?
  mut previous_control : (Double, Double)?
  mut previous_quadratic : (Double, Double)?
}

///|
fn PathParser::push(self : PathParser, command : PathCommand) -> Unit {
  self.commands.push(command)
  self.last = Some(command.destination())
}

///|
fn within_delta(a : Double, b : Double) -> Bool {
  (a - b).abs() < 1.0e-10
}

///|
fn PathParser::command(
  self : PathParser,
  upper : Char,
  relative : Bool,
  groups : Array[Array[Double]],
) -> Unit {
  let (lx, ly) = self.last.unwrap_or((0.0, 0.0))
  let rel = relative && self.last is Some(_)
  match upper {
    'M' => {
      let g = groups[0]
      let (x, y) = if rel { (g[0] + lx, g[1] + ly) } else { (g[0], g[1]) }
      self.subpath_start = Some((x, y))
      self.push(Move(x, y))
      if groups.length() > 1 {
        self.command('L', relative, groups[1:].to_owned())
        return
      }
    }
    'Z' =>
      match self.subpath_start {
        Some((x, y)) => self.push(ClosePath(x, y))
        None => ()
      }
    'L' =>
      for g in groups {
        let (lx, ly) = self.last.unwrap_or((0.0, 0.0))
        let (x, y) = if relative && self.last is Some(_) {
          (g[0] + lx, g[1] + ly)
        } else {
          (g[0], g[1])
        }
        self.push(Line(x, y))
      }
    'H' =>
      for g in groups {
        let (lx, ly) = self.last.unwrap_or((0.0, 0.0))
        let x = if relative && self.last is Some(_) { g[0] + lx } else { g[0] }
        self.push(Line(x, ly))
      }
    'V' =>
      for g in groups {
        let (lx, ly) = self.last.unwrap_or((0.0, 0.0))
        let y = if relative && self.last is Some(_) { g[0] + ly } else { g[0] }
        self.push(Line(lx, y))
      }
    'C' =>
      for g in groups {
        let (lx, ly) = self.last.unwrap_or((0.0, 0.0))
        let d = if relative && self.last is Some(_) {
          (lx, ly)
        } else {
          (0.0, 0.0)
        }
        let x1 = g[0] + d.0
        let y1 = g[1] + d.1
        let x2 = g[2] + d.0
        let y2 = g[3] + d.1
        let x = g[4] + d.0
        let y = g[5] + d.1
        self.previous_control = Some((x2, y2))
        self.push(Curve(x, y, x1, y1, x2, y2))
      }
    'S' =>
      for g in groups {
        let (lx, ly) = self.last.unwrap_or((0.0, 0.0))
        let d = if relative && self.last is Some(_) {
          (lx, ly)
        } else {
          (0.0, 0.0)
        }
        let x2 = g[0] + d.0
        let y2 = g[1] + d.1
        let x = g[2] + d.0
        let y = g[3] + d.1
        let (x1, y1) = match self.previous_control {
          Some((px, py)) => (2.0 * lx - px, 2.0 * ly - py)
          None => (lx, ly)
        }
        self.previous_control = Some((x2, y2))
        self.push(Curve(x, y, x1, y1, x2, y2))
      }
    'Q' | 'T' =>
      for g in groups {
        let (lx, ly) = self.last.unwrap_or((0.0, 0.0))
        let d = if relative && self.last is Some(_) {
          (lx, ly)
        } else {
          (0.0, 0.0)
        }
        let (x1, y1, x, y) = if upper == 'T' {
          let (x1, y1) = match self.previous_quadratic {
            Some((px, py)) => (2.0 * lx - px, 2.0 * ly - py)
            None => (lx, ly)
          }
          (x1, y1, g[0] + d.0, g[1] + d.1)
        } else {
          (g[0] + d.0, g[1] + d.1, g[2] + d.0, g[3] + d.1)
        }
        let cx1 = lx + (x1 - lx) * 2.0 / 3.0
        let cy1 = ly + (y1 - ly) * 2.0 / 3.0
        let cx2 = cx1 + (x - lx) / 3.0
        let cy2 = cy1 + (y - ly) / 3.0
        self.previous_quadratic = Some((x1, y1))
        self.push(Curve(x, y, cx1, cy1, cx2, cy2))
      }
    'A' => {
      guard self.last is Some(_) else { return }
      for g in groups {
        let (x1, y1) = self.last.unwrap_or((0.0, 0.0))
        let mut rx = g[0]
        let mut ry = g[1]
        if rx == 0.0 && ry == 0.0 {
          return
        }
        let (x2, y2) = if relative {
          (g[5] + x1, g[6] + y1)
        } else {
          (g[5], g[6])
        }
        let fa = g[3]
        let fs = g[4]
        rx = rx.abs()
        ry = ry.abs()
        let phi = ruby_mod(g[2], 360.0) * 2.0 * @math.PI / 360.0
        if within_delta(x1, x2) && within_delta(y1, y2) {
          return
        }
        if within_delta(rx, 0.0) || within_delta(ry, 0.0) {
          self.push(Line(x2, y2))
          return
        }
        let xp1 = @math.cos(phi) * ((x1 - x2) / 2.0) +
          @math.sin(phi) * ((y1 - y2) / 2.0)
        let yp1 = -@math.sin(phi) * ((x1 - x2) / 2.0) +
          @math.cos(phi) * ((y1 - y2) / 2.0)
        let hat = xp1 * xp1 / (rx * rx) + yp1 * yp1 / (ry * ry)
        if hat > 1.0 {
          rx *= hat.sqrt()
          ry *= hat.sqrt()
        }
        let r2x = rx * rx
        let r2y = ry * ry
        let mut square = (r2x * r2y - r2x * yp1 * yp1 - r2y * xp1 * xp1) /
          (r2x * yp1 * yp1 + r2y * xp1 * xp1)
        if square < 0.0 && square > -1.0e-10 {
          square = 0.0
        }
        let mut base = square.sqrt()
        if fa == fs {
          base = -base
        }
        let cpx = base * rx * yp1 / ry
        let cpy = base * -ry * xp1 / rx
        let cx = @math.cos(phi) * cpx + -@math.sin(phi) * cpy + (x1 + x2) / 2.0
        let cy = @math.sin(phi) * cpx + @math.cos(phi) * cpy + (y1 + y2) / 2.0
        let mut vx = (xp1 - cpx) / rx
        let mut vy = (yp1 - cpy) / ry
        let mut theta_1 = @math.acos(vx / (vx * vx + vy * vy).sqrt())
        if vy < 0.0 {
          theta_1 = -theta_1
        }
        let ux = vx
        let uy = vy
        vx = (-xp1 - cpx) / rx
        vy = (-yp1 - cpy) / ry
        let numerator = ux * vx + uy * vy
        let denominator = (ux * ux + uy * uy).sqrt() *
          (vx * vx + vy * vy).sqrt()
        let mut division = numerator / denominator
        if division < -1.0 {
          division = -1.0
        }
        let mut d_theta = ruby_mod(@math.acos(division), 2.0 * @math.PI)
        if ux * vy - uy * vx < 0.0 {
          d_theta = -d_theta
        }
        if fs == 0.0 {
          if d_theta > 0.0 {
            d_theta -= 2.0 * @math.PI
          }
        } else if d_theta < 0.0 {
          d_theta += 2.0 * @math.PI
        }
        let theta_2 = theta_1 + d_theta
        for curve in arc_to_bezier(cx, cy, rx, ry, theta_1, theta_2, phi) {
          self.push(curve)
        }
      }
    }
    _ => ()
  }
  if upper != 'C' && upper != 'S' {
    self.previous_control = None
  }
  if upper != 'Q' && upper != 'T' {
    self.previous_quadratic = None
  }
}

///|
/// Ruby's `Float#%` (the result takes the divisor's sign).
fn ruby_mod(a : Double, b : Double) -> Double {
  let r = a - b * (a / b).floor()
  r
}

///|
fn arc_to_bezier(
  cx : Double,
  cy : Double,
  a : Double,
  b : Double,
  lambda_1 : Double,
  lambda_2 : Double,
  theta : Double,
) -> Array[PathCommand] {
  let e = fn(eta : Double) {
    (
      cx +
      a * @math.cos(theta) * @math.cos(eta) -
      b * @math.sin(theta) * @math.sin(eta),
      cy +
      a * @math.sin(theta) * @math.cos(eta) +
      b * @math.cos(theta) * @math.sin(eta),
    )
  }
  let ep = fn(eta : Double) {
    (
      -a * @math.cos(theta) * @math.sin(eta) -
      b * @math.sin(theta) * @math.cos(eta),
      -a * @math.sin(theta) * @math.sin(eta) +
      b * @math.cos(theta) * @math.cos(eta),
    )
  }
  let mut iterations = 1
  let mut d_lambda = lambda_2 - lambda_1
  while iterations < 1024 {
    if d_lambda.abs() <= @math.PI / 2.0 {
      break
    }
    iterations *= 2
    d_lambda = (lambda_2 - lambda_1) / iterations.to_double()
  }
  let out = []
  for i in 0..<iterations {
    let l1 = lambda_1 + i.to_double() * d_lambda
    let l2 = lambda_1 + (i + 1).to_double() * d_lambda
    // 2.2.1: the parametric angles
    let eta_a = @math.atan2(@math.sin(l1) / b, @math.cos(l1) / a)
    let mut eta_b = @math.atan2(@math.sin(l2) / b, @math.cos(l2) / a)
    eta_b -= 2.0 * @math.PI * ((eta_b - eta_a) / (2.0 * @math.PI)).floor()
    if l2 - l1 > @math.PI && eta_b - eta_a < @math.PI {
      eta_b += 2.0 * @math.PI
    }
    let d_eta = eta_b - eta_a
    let t = @math.tan(d_eta / 2.0)
    let alpha = @math.sin(d_eta) * (((4.0 + 3.0 * t * t).sqrt() - 1.0) / 3.0)
    let (x1, y1) = e(eta_a)
    let (x2, y2) = e(eta_b)
    let (ex1, ey1) = ep(eta_a)
    let (ex2, ey2) = ep(eta_b)
    out.push(
      Curve(
        x2,
        y2,
        x1 + alpha * ex1,
        y1 + alpha * ey1,
        x2 - alpha * ex2,
        y2 - alpha * ey2,
      ),
    )
  }
  out
}
