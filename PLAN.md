# Prawn for MoonBit: plan

Goal: a MoonBit Prawn as good as the Ruby original. It should offer the same capabilities, make the
same layout decisions and behave the same way, built on
[moonbitlang/pdflite and pagelayout](https://github.com/moonbitlang/office.mbt).

Upstream: `.repos/prawn` (prawnpdf/prawn @ `c5be930c` = 2.5.0 + 16 commits, ~11.8k lines in `lib/`,
839 RSpec examples, ~100 manual example programs). Companion gems are unpacked in `.repos/gems/`:
pdf-core 0.10.0, ttfunk 1.8.0, prawn-table 0.2.2, prawn-svg 0.40.4 (+ css_parser 3.2.0),
prawn-icon 4.1.0, prawn-templates 0.1.2 (+ pdf-reader 2.16).

Starting point: the layout factored out of asciidoctor.mbt's PDF backend, published as
`bobzhang/prawn` 0.1.0 and used by `bobzhang/asciidoctor-pdf` 0.2.0. It covers Prawn 2.4.0's
cursor/bounds/columns/pages (`Flow`), formatted text and line wrapping (`typeset_lines`,
`Flow::typeset`, `Flow::typeset_box`), AFM/TTF metrics with fallback and icon fonts
(`FontCatalog`, `Face`), a prawn-svg 0.34.2 port (`svg/`) and prawn-table sizing (`table/`). It is
checked end to end by asciidoctor.mbt's comparison with Ruby Asciidoctor PDF.

The superseded first draft (a line-by-line pdf-core/ttfunk port aiming at byte-identical PDFs) and
Codex's review of it are in git history and `docs/plan-review-codex.md`.

## 0. Decisions (2026-10-02)

| Topic | Decision |
|---|---|
| Stack | prawn.mbt → `moonbitlang/pagelayout` → `moonbitlang/pdflite`. No pdf-core or ttfunk port |
| Upstream work | Missing capabilities go into pdflite/pagelayout as **general features** with their own tests and docs (useful to every pdflite user), as focused PRs to `moonbitlang/office.mbt`. Nothing Prawn-only goes upstream: Prawn's policies stay here |
| Who benefits | pdflite/pagelayout users get the general features; prawn.mbt gets a complete Prawn; asciidoctor-pdf gets each prawn release (its Ruby comparison is a main source of prawn bugs) |
| Fidelity | Prawn's **decisions**, not its bytes: page count and sizes, each glyph's font, size and position, line breaks, graphics, images, links/outline/destinations, and behaviour (cursor, bounds, remainders, errors). Serialization is pdflite's (§3) |
| Releases | asciidoctor-pdf depends only on published prawn versions; release prawn first, then bump it there. Breaking API changes bump the minor version |
| Scope | Prawn core first, then prawn-table (beyond sizing), prawn-svg, prawn-icon, prawn-templates |
| Review | Small PRs, each reviewed by Codex CLI (read-only, high/xhigh) with CI green before merge |

## 1. Architecture

* **Grow 0.1.0, keep it working.** Add a Prawn-shaped `Document` API (pages, cursor, bounding
  boxes, text, graphics, fonts, images, navigation) on top of and around the existing `Flow`, and
  move asciidoctor-pdf onto it over time. `Flow` and friends stay until asciidoctor-pdf no longer
  needs them.
* **Output.** Layout produces pagelayout page items where pagelayout's IR fits; content it can't
  express goes to pdflite's object and content-stream API directly. Where neither can express
  something Prawn does (a graphics state, an annotation type, an image kind), add it upstream as a
  general feature.
* **One root package for Prawn.** `Document` mixes in ~15 Ruby modules that call each other freely,
  and `Font`/`BoundingBox`/`Text::Box` hold document back-pointers, so splitting creates cycles.
  Many cohesive files, not necessarily Ruby's file boundaries. `svg/`, `table/`, `icon/`,
  `templates/` sit on top.
* **Synchronous, pure core.** Fonts, images, SVG and PDF templates are passed as bytes or resolved
  through an asset loader over preloaded assets; an optional `io/` package (moonbitlang/async)
  preloads files and writes output.
* **Ruby idioms → MoonBit**
  - option hashes → labeled optional params; internally typed option records that preserve
    "unset/inherit" vs explicit `false`/`0`, resolved at the same stage as Ruby (formatted boxes
    inherit direction, spacing, kerning from document state, `text/formatted/box.rb:186`);
  - `bounding_box { … }` / `float` / `repeat` / `stamp` / `transparent` / `column_box` → closures,
    with specified state restoration on error and across page changes; repeater/page hooks get
    explicit lifetime and ordering contracts;
  - `Prawn::View` → a trait with a `document()` accessor and forwarding default methods;
  - formatted-text fragments → `Fragment`; callbacks → ordered callback objects with
    underlay/overlay phases, suppressed during dry runs (`box.rb:332`);
  - text box extension points → explicit policy hooks (fallback font selection, justification,
    vertical alignment, decoration, wrapping), as asciidoctor-pdf overrides them
    (`asciidoctor-pdf/lib/asciidoctor/pdf/ext/prawn/formatted_text/box.rb`), plus rich layout
    results (consumed fragments, remainder, line metrics) and a scratch/checkpoint mechanism in
    place of Ruby's Marshal cloning;
  - exceptions → `suberror PrawnError { CannotFit, UnknownFont, … }`; `Prawn.debug` option checks
    → validation errors.
* **Strings.** Unicode text is scanned by scalar; AFM fonts measure on Windows-1252 bytes as Prawn
  does (`fonts/afm.rb:141`, `:301`); binary data is `Bytes`.

## 2. Upstream work in office.mbt (candidates, to verify against current APIs)

Each is a general pdflite/pagelayout feature, proposed as its own PR with tests:

| Capability | Why Prawn needs it | General value |
|---|---|---|
| AFM glyph-name kerning (incl. `C -1` glyphs) and glyph bboxes | kerned std-14 text | correct std-14 kerning for everyone |
| PNG: transparency info, translucent palettes, all bit depths/colour types | Prawn's image support | PNG coverage |
| JPEG: bits per component, CMYK/grey, Adobe inversion | `image` with any JPEG | JPEG coverage |
| TrueType/OpenType subsetting quality (composites, CFF, TTC, dfont) | Prawn's font support | smaller, more correct embedded fonts |
| Graphics state: soft masks, blend modes, transparency groups, dash/cap/join, patterns/shadings | Prawn graphics | richer drawing API |
| Annotations, destinations, outlines, page labels, name trees | Prawn navigation | navigation for every document |
| Security (RC4/AES, permissions) | `encrypt_document` | encryption for everyone |
| Reader: text positions, font decoding, form recursion | the test comparator (§3); prawn-templates | PDF inspection and import |

## 3. Fidelity and testing

* **Oracle.** Ruby Prawn from `.repos` (pinned Ruby and gems, frozen clock/TZ/RNG).
* **Comparator.** Read both PDFs with pdflite's reader and compare decisions: pages and sizes; text
  runs (string, font, size, position to a small tolerance, character spacing); graphics operators
  after normalizing serialization (number formatting, resource names, operator grouping); images
  (decoded); annotations, destinations, outline, page labels. Exact bytes are never required.
* **Operation scripts.** A JSON op language with nested scopes (bounding_box, float, column_box,
  repeat, stamp), explicit assets and **queries** (cursor, bounds, `width_of`, `height_of`, text box
  remainder, page count). It is run by a Ruby driver and by `cmd/oracle` and compared as above.
  Translate representative RSpec examples and every manual example once.
* **Generators** for boundaries (widths within ε of measured values, Unicode scalars, fallback
  switches, page breaks), with shrinking; minimized failures kept as regression scripts.
* **asciidoctor-pdf** remains an end-to-end check: its comparison failures that trace to Prawn
  become prawn.mbt issues with an op-script reproduction.
* Gates exit non-zero on unexpected differences; known failures are categorized; record counts
  guarded; `scripts/check.mbtx` runs everything; tests on native, wasm-gc, js.

## 4. Milestones

| # | Milestone | Exit criterion |
|---|---|---|
| 0 | Oracle harness: Ruby driver, comparator on pdflite's reader, `scripts/check.mbtx` | seed scripts compare clean twice in a row |
| 1 | `Document` core: page setup, margins, cursor, bounding/column boxes, `move_down`/`pad`/`float`, page navigation | bounding_box/column_box/document specs as op scripts |
| 2 | Text: `text`, `text_box`, `formatted_text`, inline format, `draw_text`, overflow modes (truncate, shrink_to_fit, expand), alignment/valign, leading, spacing, rotation; std-14 AFM with kerning | text specs and manual text section |
| 3 | Graphics: paths, shapes, colours (RGB/CMYK), stroke styles, transformations, transparency, soft masks, gradients | graphics specs and manual |
| 4 | Fonts: TTF/OTF/TTC/dfont, subsetting, fallback fonts, kerning | font specs |
| 5 | Images: PNG (all types, transparency), JPEG; inline images via fragment callbacks | images specs |
| 6 | Navigation and repeated content: outline, links, destinations, annotations, page labels, `number_pages`, repeaters, stamps, grid, `View` | remaining specs; manual outline/repeatable_content |
| 7 | Security; prawn-templates on pdflite's reader | specs |
| 8 | prawn-table (full), prawn-svg upgrade, prawn-icon | their specs and manuals |
| 9 | Full manual compares clean; API review (Codex); release | publish |

## 5. Pitfalls

* Ruby number semantics where they reach layout: `/` and `%` floor, `round` half away from zero,
  `Float#floor` returns Integer; keep Ruby's floating-point operation order in measurements.
* Prawn facts already found: glyph widths truncated to 1/1000 em; line wrap pulls back only the
  previous fragment's last word; name-tree duplicates resolve to the last added.
* Transcendental functions in rotations: check native/wasm/js agree with Ruby's libm on test
  angles.
* Malformed inputs (bad encodings, truncated images/fonts) fail like Ruby; record any intentional
  deviation in a compatibility-limits section.

## 6. Open questions

* **Licence.** Prawn, pdf-core and TTFunk are under Ruby's licence / GPLv2 / GPLv3. Code adapted
  from them keeps Matz's terms with a NOTICE (`NOTICE`, `LICENSES/LICENSE-prawn`); the module is
  MIT otherwise.
* **Versions.** Upstream here is Prawn 2.5 / prawn-svg 0.40; asciidoctor-pdf 2.3.27 pins Prawn
  2.4.0, and `svg/` ports prawn-svg 0.34.2. Record the behaviour asciidoctor-pdf needs from the
  older pins.
* **0.1.0 API cleanup** (from asciidoctor.mbt's TODO): move converter-only `Style.text_transform`
  and `default_font_files` back to asciidoctor-pdf; stop exposing `build_items`/`Item`; `Flow` is
  `pub(all)` for now.
* **SVG regression coverage** (Codex nit on asciidoctor.mbt#7): SVG under different documents'
  font scopes; bounds-dependent SVG in a section title loaded after a differently sized document.

## 7. Status log

* 2026-10-02: imported `prawn/` from asciidoctor.mbt with its history (46 tests pass standalone);
  repository github.com/bobzhang/prawn.mbt. Plan rebased onto pdflite/pagelayout.
