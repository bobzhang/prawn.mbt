///|
// compare: the PDF half of the comparison with Ruby Prawn (PLAN.md §3).
//
//   compare diff EXPECTED.pdf ACTUAL.pdf
//     Print how ACTUAL differs from EXPECTED; fail when it does.
//   compare inspect FILE.pdf
//     Print what the comparison sees: every page's glyphs and marks (JSON).
//   compare mutate KIND IN.pdf OUT.pdf
//     Write a mutated copy of IN (see `@inspect.mutations`).
//   compare self-test DIR
//     Check the comparison on every PDF in DIR: each negative mutation must
//     be reported as a difference and each positive one must not.

///|
fn usage() -> String {
  "usage: compare diff EXPECTED ACTUAL | inspect FILE | mutate KIND IN OUT | self-test DIR"
}

///|
async fn read(path : String) -> Bytes {
  @fs.read_file(path).binary()
}

///|
/// Runs the controls on one PDF; the violations.
fn self_test_one(
  name : String,
  bytes : Bytes,
  applied : Map[String, Int],
) -> Array[String] raise {
  let original = @inspect.inspect(bytes)
  let violations : Array[String] = []
  for entry in @inspect.mutations {
    let (kind, control) = entry
    guard @inspect.mutate(bytes, kind) is Some(mutated) else { continue }
    applied[kind] = applied.get(kind).unwrap_or(0) + 1
    let differences = @inspect.compare(original, @inspect.inspect(mutated))
    match (control, differences.is_empty()) {
      (Negative, true) => violations.push("\{name} \{kind}: not detected")
      (Positive, false) =>
        violations.push("\{name} \{kind}: reported \{differences[0]}")
      _ => ()
    }
  }
  violations
}

///|
async fn main {
  let args = @env.args()
  match args.get(1).unwrap_or("") {
    "diff" if args.length() == 4 => {
      let differences = @inspect.compare(
        @inspect.inspect(read(args[2])),
        @inspect.inspect(read(args[3])),
      )
      for d in differences {
        @stdio.stdout.write(d + "\n")
      }
      if !differences.is_empty() {
        fail("\{differences.length()} difference(s)")
      }
    }
    "inspect" if args.length() == 3 => {
      let pages = @inspect.inspect(read(args[2]))
      @stdio.stdout.write(
        Json::array(pages.map(p => p.to_json())).stringify() + "\n",
      )
    }
    "mutate" if args.length() == 5 =>
      match @inspect.mutate(read(args[3]), args[2]) {
        Some(bytes) =>
          @fs.write_file(args[4], bytes, create_mode=CreateOrTruncate)
        None => fail("\{args[2]} does not apply to \{args[3]}")
      }
    "self-test" if args.length() == 3 => {
      let dir = args[2]
      let files = @fs.readdir(dir, sort=true).filter(f => f.has_suffix(".pdf"))
      if files.is_empty() {
        fail("no PDFs in \{dir}")
      }
      let violations : Array[String] = []
      let applied : Map[String, Int] = Map([])
      for file in files {
        violations.append(self_test_one(file, read("\{dir}/\{file}"), applied))
      }
      for v in violations {
        @stdio.stdout.write(v + "\n")
      }
      for entry in @inspect.mutations {
        let n = applied.get(entry.0).unwrap_or(0)
        @stdio.stdout.write("  \{entry.0}: applied to \{n} PDF(s)\n")
        if n == 0 {
          violations.push("\{entry.0}: applied to no PDF")
        }
      }
      @stdio.stdout.write(
        "self-test: \{files.length()} PDFs × \{@inspect.mutations.length()} mutations, \{violations.length()} violation(s)\n",
      )
      if !violations.is_empty() {
        fail("the comparison failed its controls")
      }
    }
    _ => {
      @stdio.stderr.write(usage() + "\n")
      fail("bad arguments")
    }
  }
}
