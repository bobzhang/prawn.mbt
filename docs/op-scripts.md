# Operation scripts

An operation script is a JSON program against Prawn's `Document` API. The same script runs through
Ruby Prawn (`scripts/oracle/driver.rb`, the oracle) and through this module, and the two runs are
compared: the rendered PDFs under the fidelity contract in `PLAN.md` §3, and the observation logs
exactly. Scripts live in `tests/ops/`. `scripts/oracle.mbtx` runs them through Ruby.

```json
{
  "document": { "page_size": "A4", "margin": 50 },
  "ops": [
    ["text", "Hello", { "size": 14, "align": ":center" }],
    ["?cursor"],
    ["bounding_box", [50, 600], { "width": 200 }, { "block": [["text", "inside"], ["?bounds"]] }]
  ]
}
```

## Document

`document` holds the options of `Prawn::Document.new`. It is optional.

## Ops

Each op is an array: a method name, then its arguments.

* **Method paths.** The name is a method of the document, or a dotted path to one
  (`font_families.update`, `bounds.width`).
* **Options.** A trailing object with keys is passed as the options (Ruby keyword arguments).
* **Blocks.** A trailing `{ "block": [ops] }` becomes the method's block (`bounding_box`, `float`,
  `indent`, `font`, `transparent`, `rotate`, `column_box`, `repeat`, …); its other keys, if any,
  are options (`{ "origin": [400, 500], "block": [...] }`). Inside the block, ops run against the
  document, or against the block's receiver when Prawn `instance_eval`s it (`outline.define`).
* **Queries.** A `?` before the name logs the return value: `["?cursor"]`,
  `["?width_of", "AVATAR", { "size": 18 }]`, `["?text_box", "…", { … }]` (the remainder).
* **Expected errors.** `["!raises", "Prawn::Errors::CannotFit", OP]` runs `OP` and logs the class
  of the error it raised (`null` when none). The expectation is recorded alongside, so a script
  documents what it expects (`"none"` when it should succeed), and the comparison checks both
  implementations log the same class.

## Values

JSON maps onto Ruby as follows:

| JSON | Ruby |
|---|---|
| integer / number with a fraction | `Integer` / `Float` (`1` and `1.0` stay distinct) |
| `":name"` | the symbol `:name`; `"::text"` is the literal string `":text"` |
| `"$PRAWN/path"` | a file in the Prawn checkout (`.repos/prawn/path`), e.g. its `data/fonts` |
| object keys | symbols; a `=` prefix keeps a string key (`{ "=DejaVu": { "normal": "…" } }`) |
| `{ "trace": ID }` in a fragment's `callback` | a callback that logs `render_behind` and `render_in_front` with the fragment's text and geometry; `"phase": "behind"` or `"in_front"` logs only one |
| `{ "trace": ID }` as `draw_text_callback` | a callback that logs each `draw_text` call (text, `at`, `kerning`) instead of drawing |

## Observation log

One JSON object per line, in the order things happened:

| entry | when |
|---|---|
| `{"query": NAME or [NAME, args…], "value": V}` | a `?` op |
| `{"raises": EXPECTED, "error": CLASS or null}` | a `!raises` op |
| `{"trace": ID, "event": …, …}` | a traced callback ran |
| `{"warning": MESSAGE}` | Prawn warned (`Kernel#warn`) |

Values are numbers, strings, booleans, `null`, arrays and objects. Symbols are logged as `":name"`,
bounding boxes as `{left, bottom, width, height, absolute_left, absolute_top}`, fragments as
`{text, width}`, and anything else as `{class}`. Paths in the Prawn checkout are logged as
`$PRAWN/…`, so logs do not depend on where the checkout is. Floats are logged as Ruby prints
them, so `1.0` and `1` stay distinct.

## Determinism

`moon run --target native scripts/oracle.mbtx -- --determinism` runs every script twice and fails
unless the PDFs and logs are byte-identical. The driver fixes Ruby's warning settings
(`$VERBOSE = false`, deprecation and experimental warnings off), so an inherited `RUBYOPT` cannot
change the log. Scripts must not depend on the clock or randomness (set `info` dates explicitly,
never use `:random` passwords).

Examples that need mocks, extension subclasses or object identity are not op scripts; they are
hand-ported as MoonBit tests.

## Goldens and the comparison

`scripts/oracle.mbtx` writes Ruby's outputs to `tests/golden` (`NAME.pdf`, `NAME.jsonl`), which
are committed, so the comparison runs without Ruby. `moon run --target native scripts/check.mbtx --
--oracle` reruns Ruby and requires the goldens to be unchanged.

`cmd/compare` (on `internal/inspect`) reads PDFs with pdflite and compares what they show under
the contract in `PLAN.md` §3:

* `compare diff EXPECTED ACTUAL` prints the differences, under a rule per field:
  - *exact:* page count, sizes and rotation, each glyph's text, font, `Tf` size and render mode,
    colour spaces, alpha, blend modes, soft masks, path structure (segment kinds, closure,
    winding rule), stroke style (cap, join, miter limit, number of dashes), image dictionaries
    and data hashes (decoded where pdflite decodes, a DCT stream's own bytes otherwise; soft
    masks included);
  - *within 0.01 pt in page space:* glyph origins and render matrices (which carry horizontal
    scaling and rotation), path points, the stroke pen (the line width as the CTM shapes it,
    the same whether the CTM is y-up or y-down) and dashes, image corners, clips;
  - *within 1e-5:* colour components;
  - *paint order:* glyphs and marks that overlap must be painted in the same relative order.

  Inspection follows the CTM into page space, walks form XObjects (stamps) with their matrix and
  bounding box, and canonicalizes equivalent serializations (`re` vs `m l l l l h`, empty
  subpaths, a dash phase with no dash).
* `compare inspect FILE` prints what the comparison sees.
* `compare self-test DIR` runs the controls on every PDF in `DIR`. Negative mutations (text moved
  0.02 pt, a font size changed, a page break moved, a colour changed by one 8-bit step, a path
  moved 0.02 pt, text 1% wider, a clip grown by 1 pt) must be reported. Positive ones (text moved
  0.004 pt, a pdflite round trip, colours written in full instead of Prawn's 5 decimals) must
  not. Every mutation must apply to at least one PDF.

Not compared yet: annotations, destinations, the outline and page labels; which pattern a
pattern colour uses (gradients); glyph outlines (glyphs are identified by font name and Unicode
text). Clips are compared as bounding boxes.

pdflite's content state keeps paths and clips in user space, so the inspector maps them to page
space itself; and its `q`/`Q` save and restore the path under construction (not part of the
graphics state), which the inspector undoes until pdflite does.

## The MoonBit side

`cmd/oracle` runs a script through this module's `Document` (`oracle SCRIPT OUT.pdf OUT.jsonl`).
Ops it cannot run yet are logged as `{"unsupported": NAME}` and skipped.
`moon run --target native scripts/compare.mbtx` runs every script through it and compares the
PDF (`compare diff`) and the log (`compare log`, numbers within 1e-6, since Ruby and MoonBit may
round the last bits differently) with the goldens, one line per script.

The comparator treats gray *g* as RGB (*g*, *g*, *g*): Prawn leaves default black in DeviceGray,
pagelayout writes RGB.

Known divergences, each kept as a failing seed: `kerning_accents` (pdflite's standard-font data
lacks the kerning pairs of unencoded glyphs, to fix upstream), `control_characters` (Prawn sets
a tab or carriage return inside a line as a glyph; Flow drops it), `callback_whitespace` (Prawn calls
the callbacks of a fragment piece trimmed to nothing, with empty text and no width; Flow drops
the piece) and `transform_left_open` (a
transformation block that ends on another page leaves its `q … cm` open on the page it began on,
so Prawn transforms what is drawn there later; this module closes it). Prawn writes invalid PDF
for a path left open across a transformation block's `q`/`Q` or `cm`; such cases are not compared.

Ruby's integer arithmetic is not reproduced: where Prawn divides integers (a column box's
`(width - spacer * (columns - 1)) / columns` with integer width and spacer), Ruby floors and this
module divides exactly. Seeds use values that divide evenly.
