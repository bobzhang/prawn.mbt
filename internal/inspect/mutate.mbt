///|
/// Controls for the comparison itself (PLAN.md §3): a negative mutation must
/// make a PDF compare differently from its original, a positive one must
/// not.
pub(all) enum Control {
  Negative
  Positive
}

///|
/// The mutations, with what each must do.
pub let mutations : Array[(String, Control)] = [
  // the first text object moves right by 0.02 pt
  ("shift-text", Negative),
  // the first font size grows by 0.05
  ("font-size", Negative),
  // the first text object of the last page with text moves to a new page
  ("page-break", Negative),
  // the first fill colour changes by one 8-bit step
  ("colour", Negative),
  // the first path point moves up by 0.02 pt
  ("shift-path", Negative),
  // the first text object moves right by 0.004 pt
  ("jitter-text", Positive),
  // pdflite reads and writes the PDF again
  ("roundtrip", Positive),
  // colours Prawn rounded to 5 decimals (128/255 as 0.50196) written in
  // full, as pdflite writes them
  ("unround-colour", Positive),
]

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
/// Applies mutation `kind` to a PDF; `None` when it does not apply (no text,
/// no colour, …).
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
  match kind {
    "shift-text" | "jitter-text" => {
      let dx = if kind == "shift-text" { 0.02 } else { 0.004 }
      for p, ops in all_ops {
        guard first_text_object(ops) is Some((start, _)) else { continue }
        // q, a translation, BT … ET, Q: the whole text object moves
        ops.insert(
          start,
          Op_cm({ a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: dx, f: 0.0, }),
        )
        ops.insert(start, Op_q)
        // the matching ET is now 2 later
        guard first_text_object(ops) is Some((_, stop)) else { continue }
        ops.insert(stop + 1, Op_Q)
        set_ops(p)
        changed = true
        break
      }
    }
    "font-size" =>
      for p, ops in all_ops {
        if rewrite_first(ops, op => {
            match op {
              Op_Tf(name, size) => Some(Op_Tf(name, size + 0.05))
              _ => None
            }
          }) {
          set_ops(p)
          changed = true
          break
        }
      }
    "page-break" => {
      let mut last = -1
      for p, ops in all_ops {
        if first_text_object(ops) is Some(_) {
          last = p
        }
      }
      if last >= 0 {
        let ops = all_ops[last]
        guard first_text_object(ops) is Some((start, stop)) else { return None }
        // keep the font: a text object may rely on a Tf set before it
        let moved : Array[@content.PdfContentOp] = []
        for i in 0..<start {
          match ops[i] {
            Op_Tf(_) as tf => moved.push(tf)
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
        let page = pages[last]
        pages.insert(last + 1, {
          ..page,
          content: [@pdflite.pdf_content_stream_of_ops(moved)],
        })
        changed = true
      }
    }
    "colour" =>
      for p, ops in all_ops {
        if rewrite_first(ops, op => {
            match op {
              Op_rg(r, g, b) => Some(Op_rg(step(r), g, b))
              Op_g(x) => Some(Op_g(step(x)))
              Op_k(c, m, y, k) => Some(Op_k(step(c), m, y, k))
              Op_sc(xs) if xs.length() > 0 => Some(Op_sc(stepped(xs)))
              Op_scn(xs) if xs.length() > 0 => Some(Op_scn(stepped(xs)))
              _ => None
            }
          }) {
          set_ops(p)
          changed = true
          break
        }
      }
    "unround-colour" =>
      for p, ops in all_ops {
        let mut any = false
        for i, op in ops {
          match op {
            Op_rg(r, g, b) => {
              ops[i] = Op_rg(unround(r), unround(g), unround(b))
              any = true
            }
            Op_RG(r, g, b) => {
              ops[i] = Op_RG(unround(r), unround(g), unround(b))
              any = true
            }
            Op_sc(xs) => {
              ops[i] = Op_sc(xs.map(unround))
              any = true
            }
            Op_scn(xs) => {
              ops[i] = Op_scn(xs.map(unround))
              any = true
            }
            Op_SC(xs) => {
              ops[i] = Op_SC(xs.map(unround))
              any = true
            }
            Op_SCN(xs) => {
              ops[i] = Op_SCN(xs.map(unround))
              any = true
            }
            _ => ()
          }
        }
        if any {
          set_ops(p)
          changed = true
        }
      }
    "shift-path" =>
      for p, ops in all_ops {
        if rewrite_first(ops, op => {
            match op {
              Op_m(x, y) => Some(Op_m(x, y + 0.02))
              Op_re(x, y, w, h) => Some(Op_re(x, y + 0.02, w, h))
              _ => None
            }
          }) {
          set_ops(p)
          changed = true
          break
        }
      }
    other => fail("unknown mutation \{other}")
  }
  if !changed {
    return None
  }
  Some(
    @pdflite.pdf_write_document(doc.change_pages(pages, change_references=true)),
  )
}

///|
fn stepped(xs : Array[Double]) -> Array[Double] {
  let out = xs.copy()
  out[0] = step(out[0])
  out
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
