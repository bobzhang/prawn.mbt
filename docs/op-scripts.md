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
  `indent`, `font`, `transparent`, `rotate`, `column_box`, `repeat`, …). Inside it, the ops run
  against the same document.
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
| `":name"` | the symbol `:name` |
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
`{text, width}`, and anything else as `{class}`. Floats are logged as Ruby prints them, so `1.0`
and `1` stay distinct.

## Determinism

`moon run --target native scripts/oracle.mbtx -- --determinism` runs every script twice and fails
unless the PDFs and logs are byte-identical. Scripts must not depend on the clock or randomness
(set `info` dates explicitly, never use `:random` passwords).

Examples that need mocks, extension subclasses or object identity are not op scripts; they are
hand-ported as MoonBit tests.
