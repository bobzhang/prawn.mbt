///|
/// Controls for the comparison itself (PLAN.md §3): a negative mutation must
/// make a PDF compare differently from its original, a positive one must
/// not.
pub(all) enum Control {
  Negative
  Positive
}

///|
/// The mutations, with what each must do. Distances are in page space.
pub let mutations : Array[(String, Control)] = [
  // the first text object moves right by 0.02 pt
  ("shift-text", Negative),
  // the first font size grows by 0.05
  ("font-size", Negative),
  // the first text object of the last page with text moves to a new page
  ("page-break", Negative),
  // the first fill colour changes by one 8-bit step
  ("colour", Negative),
  // the first painted path moves up by 0.02 pt
  ("shift-path", Negative),
  // the first text object is shown 1% wider
  ("hscale", Negative),
  // the first rectangular clip grows by 1 pt
  ("clip", Negative),
  // the first text object moves right by 0.004 pt
  ("jitter-text", Positive),
  // pdflite reads and writes the PDF again
  ("roundtrip", Positive),
  // colours Prawn rounded to 5 decimals (128/255 as 0.50196) written in
  // full, as pdflite writes them
  ("unround-colour", Positive),
]

///|
let identity : @geometry.TransformMatrix = {
  a: 1.0,
  b: 0.0,
  c: 0.0,
  d: 1.0,
  e: 0.0,
  f: 0.0,
}

///|
fn translate(dx : Double, dy : Double) -> @geometry.TransformMatrix {
  { ..identity, e: dx, f: dy, }
}

///|
/// The CTM in effect before each op (q, Q and cm tracked).
fn ctms(ops : Array[@content.PdfContentOp]) -> Array[@geometry.TransformMatrix] {
  let out : Array[@geometry.TransformMatrix] = []
  let stack : Array[@geometry.TransformMatrix] = []
  let mut ctm = identity
  for op in ops {
    out.push(ctm)
    match op {
      Op_q => stack.push(ctm)
      Op_Q => ctm = stack.pop().unwrap_or(identity)
      Op_cm(m) => ctm = @geometry.transform_matrix_compose(ctm, m)
      _ => ()
    }
  }
  out
}

///|
/// A user-space translation that moves things by (dx, dy) in page space
/// under `ctm`.
fn page_translation(
  ctm : @geometry.TransformMatrix,
  dx : Double,
  dy : Double,
) -> @geometry.TransformMatrix {
  // solve [a c; b d] (u, v) = (dx, dy)
  let det = ctm.a * ctm.d - ctm.b * ctm.c
  translate((ctm.d * dx - ctm.c * dy) / det, (ctm.a * dy - ctm.b * dx) / det)
}

///|
fn inverse_translation(
  m : @geometry.TransformMatrix,
) -> @geometry.TransformMatrix {
  translate(-m.e, -m.f)
}

///|
/// Moves ops `start..=stop` by (dx, dy) in page space: a translation before
/// them and its inverse after, so later state is untouched.
fn move_range(
  ops : Array[@content.PdfContentOp],
  start : Int,
  stop : Int,
  dx : Double,
  dy : Double,
) -> Unit {
  let t = page_translation(ctms(ops)[start], dx, dy)
  ops.insert(stop + 1, Op_cm(inverse_translation(t)))
  ops.insert(start, Op_cm(t))
}

///|
/// The first BT … ET range of `ops`.
fn first_text_object(ops : Array[@content.PdfContentOp]) -> (Int, Int)? {
  let mut start = -1
  for i, op in ops {
    match op {
      Op_BT => start = i
      Op_ET if start >= 0 => return Some((start, i))
      _ => ()
    }
  }
  None
}

///|
fn is_painting(op : @content.PdfContentOp) -> Bool {
  match op {
    Op_S | Op_s | Op_f | Op_F | Op_fstar | Op_B | Op_Bstar | Op_b | Op_bstar =>
      true
    _ => false
  }
}

///|
/// The first painted path: from its first construction op to its painting
/// op.
fn first_path(ops : Array[@content.PdfContentOp]) -> (Int, Int)? {
  let mut start = -1
  for i, op in ops {
    match op {
      Op_m(_) | Op_re(_) => if start < 0 { start = i }
      Op_n | Op_W | Op_Wstar => start = -1
      _ if is_painting(op) && start >= 0 => return Some((start, i))
      _ => ()
    }
  }
  None
}

///|
fn round5(x : Double) -> Double {
  (x * 100000.0).round() / 100000.0
}

///|
/// The 8-bit colour component Prawn wrote as `x` (rounded to 5 decimals),
/// in full; `x` itself when it is not one.
fn unround(x : Double) -> Double {
  let full = (x * 255.0).round() / 255.0
  if round5(full) == x {
    full
  } else {
    x
  }
}

///|
/// One 8-bit step brighter, or darker at the top of the range.
fn step(x : Double) -> Double {
  if x + 1.0 / 255.0 <= 1.0 {
    x + 1.0 / 255.0
  } else {
    x - 1.0 / 255.0
  }
}

///|
fn stepped(xs : Array[Double]) -> Array[Double] {
  let out = xs.copy()
  out[0] = step(out[0])
  out
}

///|
/// Rewrites the first op `f` changes (returning `Some`); whether one did.
fn rewrite_first(
  ops : Array[@content.PdfContentOp],
  f : (@content.PdfContentOp) -> @content.PdfContentOp?,
) -> Bool {
  for i, op in ops {
    match f(op) {
      Some(next) => {
        ops[i] = next
        return true
      }
      None => ()
    }
  }
  false
}

///|
/// The op with its colour operands un-rounded, if that changes any.
fn unrounded(op : @content.PdfContentOp) -> @content.PdfContentOp? {
  let all = fn(xs : Array[Double]) -> Array[Double]? {
    let ys = xs.map(unround)
    if ys == xs {
      None
    } else {
      Some(ys)
    }
  }
  match op {
    Op_rg(r, g, b) => all([r, g, b]).map(c => Op_rg(c[0], c[1], c[2]))
    Op_RG(r, g, b) => all([r, g, b]).map(c => Op_RG(c[0], c[1], c[2]))
    Op_g(x) => all([x]).map(c => Op_g(c[0]))
    Op_G(x) => all([x]).map(c => Op_G(c[0]))
    Op_sc(xs) => all(xs).map(c => Op_sc(c))
    Op_scn(xs) => all(xs).map(c => Op_scn(c))
    Op_SC(xs) => all(xs).map(c => Op_SC(c))
    Op_SCN(xs) => all(xs).map(c => Op_SCN(c))
    _ => None
  }
}

///|
/// Applies mutation `kind` to one page's ops; whether it applied.
fn mutate_ops(kind : String, ops : Array[@content.PdfContentOp]) -> Bool raise {
  match kind {
    "shift-text" | "jitter-text" => {
      guard first_text_object(ops) is Some((start, stop)) else { return false }
      let dx = if kind == "shift-text" { 0.02 } else { 0.004 }
      move_range(ops, start, stop, dx, 0.0)
      true
    }
    "shift-path" => {
      guard first_path(ops) is Some((start, stop)) else { return false }
      move_range(ops, start, stop, 0.0, 0.02)
      true
    }
    "hscale" => {
      guard first_text_object(ops) is Some((start, stop)) else { return false }
      // the scaling in effect there, restored before ET
      let mut scale = 100.0
      for i in 0..<start {
        if ops[i] is Op_Tz(s) {
          scale = s
        }
      }
      ops.insert(stop, Op_Tz(scale))
      ops.insert(start + 1, Op_Tz(scale * 1.01))
      true
    }
    "font-size" =>
      rewrite_first(ops, op => {
        match op {
          Op_Tf(name, size) => Some(Op_Tf(name, size + 0.05))
          _ => None
        }
      })
    "colour" =>
      rewrite_first(ops, op => {
        match op {
          Op_rg(r, g, b) => Some(Op_rg(step(r), g, b))
          Op_g(x) => Some(Op_g(step(x)))
          Op_k(c, m, y, k) => Some(Op_k(step(c), m, y, k))
          Op_sc(xs) if xs.length() > 0 => Some(Op_sc(stepped(xs)))
          Op_scn(xs) if xs.length() > 0 => Some(Op_scn(stepped(xs)))
          _ => None
        }
      })
    "clip" => {
      for i, op in ops {
        if i + 1 < ops.length() && ops[i + 1] is (Op_W | Op_Wstar) {
          match op {
            Op_re(x, y, w, h) => {
              ops[i] = Op_re(x - 1.0, y - 1.0, w + 2.0, h + 2.0)
              return true
            }
            _ => ()
          }
        }
      }
      false
    }
    "unround-colour" => {
      let mut any = false
      for i, op in ops {
        match unrounded(op) {
          Some(next) => {
            ops[i] = next
            any = true
          }
          None => ()
        }
      }
      any
    }
    other => fail("unknown mutation \{other}")
  }
}

///|
/// Applies mutation `kind` to a PDF; `None` when it does not apply (no text,
/// no colour to change, …).
pub fn mutate(bytes : Bytes, kind : String) -> Bytes? raise {
  let doc = @pdflite.pdf_decompress_pdf(
    @pdflite.pdf_read_document_from_bytes(bytes),
  )
  if kind == "roundtrip" {
    return Some(@pdflite.pdf_write_document(doc))
  }
  let pages = doc.pages_of_pagetree()
  let all_ops = pages.map(page => {
    doc.parse_content_ops_with_resources(page.resources, page.content)
  })
  let set_ops = fn(index : Int) raise {
    pages[index] = {
      ..pages[index],
      content: [@pdflite.pdf_content_stream_of_ops(all_ops[index])],
    }
  }
  let mut changed = false
  if kind == "page-break" {
    let mut last = -1
    for p, ops in all_ops {
      if first_text_object(ops) is Some(_) {
        last = p
      }
    }
    if last < 0 {
      return None
    }
    let ops = all_ops[last]
    guard first_text_object(ops) is Some((start, stop)) else { return None }
    // the state the text object relies on: the font and colours set before
    // it, under the CTM in effect there
    let moved : Array[@content.PdfContentOp] = [Op_cm(ctms(ops)[start])]
    for i in 0..<start {
      match ops[i] {
        Op_Tf(_)
        | Op_cs(_)
        | Op_scn(_)
        | Op_sc(_)
        | Op_rg(_)
        | Op_g(_)
        | Op_k(_) => moved.push(ops[i])
        _ => ()
      }
    }
    for i in start..<=stop {
      moved.push(ops[i])
    }
    for _ in start..<=stop {
      ops.remove(start) |> ignore
    }
    set_ops(last)
    pages.insert(last + 1, {
      ..pages[last],
      content: [@pdflite.pdf_content_stream_of_ops(moved)],
    })
    changed = true
  } else if kind == "unround-colour" {
    // every page, so the control covers every colour
    for p, ops in all_ops {
      if mutate_ops(kind, ops) {
        set_ops(p)
        changed = true
      }
    }
  } else {
    for p, ops in all_ops {
      if mutate_ops(kind, ops) {
        set_ops(p)
        changed = true
        break
      }
    }
  }
  if !changed {
    return None
  }
  Some(
    @pdflite.pdf_write_document(doc.change_pages(pages, change_references=true)),
  )
}
