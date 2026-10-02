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
* **Output.** Layout produces pagelayout page items, rendered by pagelayout's `render_pdf`, which
  owns painter order, resource allocation and graphics-state scoping. Content that `PageItem`
  can't express today must not be appended after rendering (that loses interleaving). Instead, add
  it to pagelayout as a general item kind (e.g. a graphics-state group, a soft mask, a shading), or
  as a general extension item carrying content operators plus the resources they need. Either way
  `render_pdf` keeps allocating resources and ordering paint. Designing this is milestone 1's
  first task, before any graphics work.
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

## 2. Upstream work in office.mbt

Each is a general pdflite/pagelayout feature, proposed as its own PR with tests. Where office.mbt
already has the capability, the work is to **qualify it against Prawn** and fix only the gaps
that come up.

**Gaps (verified 2026-10-02):**

| Capability | Today | General value |
|---|---|---|
| AFM glyph-name kerning and glyph bboxes | the parser drops kern pairs of `C -1` glyphs (`pdflite/font/afm/pdf_afm.mbt:178`); kerning is by code | correct std-14 kerning |
| PNG palette transparency, translucent palettes | rejected (`pdflite/pdf_png.mbt:155`) | PNG coverage |
| JPEG bits/colour space (grey, CMYK, Adobe inversion) | builder hardcodes 8-bit DeviceRGB (`pdflite/pdf_image_object_builders.mbt:35`) | correct JPEG embedding |
| Extension item / missing graphics in `PageItem` (§1) | no raw-content or custom-emitter variant (`pagelayout/page_model.mbt:162`) | richer drawing API |
| Reader: character/word spacing, text rise, render mode, fill/stroke colour, alpha and ExtGState in glyph and path entries; glyph identity from the font program | `PdfContentGlyphState` omits them (`pdflite/pdf_content_state.mbt:39`); glyph boxes use ascent/descent and advance (`pdflite/pdf_content_text_layout.mbt:60`) | precise PDF inspection |

**Exists; qualify against Prawn:** stroke styles (`pagelayout/graphic.mbt:113`), outline and page
labels (`pagelayout/pdf/options.mbt:67`), RC4/AES encryption with permissions
(`pdflite/pdf_writer_encryption_entrypoints.mbt:29`), decoded glyph entries
(`pdflite/pdf_content_operator_state_text.mbt:45`), recursive page-content inspection
(`pdflite/pdf_content_page_json.mbt:8`), TrueType subsetting (composites, CFF, TTC, dfont still to
check), soft masks, blend modes, patterns/shadings, annotations and destinations.

## 3. Fidelity and testing

* **Oracle.** Ruby Prawn from `.repos` (pinned Ruby and gems, frozen clock/TZ/RNG).
* **Comparator.** Read both PDFs with pdflite's reader (extended as in §2) and compare Prawn's
  decisions. Exact bytes are never required.
  - *Exact:* page count, page sizes, which page and line each glyph is on, the glyph sequence
    (canonicalized: `Tj`/`TJ` grouping ignored, subset tags stripped; a glyph in an embedded font
    is identified by Unicode plus a hash of its outline in the font program, a glyph in an
    unembedded standard-14 font by the canonical face and its encoding-resolved glyph name), font
    family and size, text render mode, colour space, alpha/blend state, annotations,
    destinations, outline, page labels.
  - *Within 0.01 pt in final page coordinates:* glyph origins, path coordinates, image placement,
    character/word spacing, rise. Ruby rounds content operands to 5 decimals
    (`pdf-core/pdf_object.rb:11`); the bound leaves room for that and for accumulated advances.
    Tighter where a test needs it.
  - *Colour components within 1e-5* (Prawn rounds its normalized channels to 5 decimals, e.g.
    128/255 is `0.50196`; pdflite keeps more digits); a positive control checks the two
    serializations agree.
  - *Images:* PNG and other Flate images compared decoded; JPEG compared on the DCT payload plus
    the image dictionary (`/ColorSpace`, `/BitsPerComponent`, `/Decode`, `/SMask`, `/Mask`),
    since pdflite doesn't decode DCT.
  - *Negative controls:* the harness checks itself on mutated outputs (a glyph displaced by
    0.02 pt, a changed font, a moved page break, a colour changed by one 8-bit step),
    which must all fail.
* **Operation scripts.** A JSON op language with nested scopes (bounding_box, float, column_box,
  repeat, stamp), explicit assets, typed numbers, **queries** (cursor, bounds, `width_of`,
  `height_of`, text box remainder, line metrics, page count), **callback traces** (fragment and
  draw-text callbacks with their arguments, including dry-run suppression), and **expected
  errors** plus the state after them. It is run by a Ruby driver and by `cmd/oracle` and compared
  as above. Translate representative RSpec examples and every manual example once. Examples that
  need mocks or extension subclasses are hand-ported as MoonBit tests.
* **Generators** for boundaries (widths within ε of measured values, Unicode scalars, fallback
  switches, page breaks), with shrinking; minimized failures kept as regression scripts.
* **asciidoctor-pdf** remains an end-to-end check: its comparison failures that trace to Prawn
  become prawn.mbt issues with an op-script reproduction.
* Gates exit non-zero on unexpected differences; known failures are categorized; record counts
  guarded; `scripts/check.mbtx` runs everything; tests on native, wasm-gc, js (js needs enabling,
  milestone 0).

## 4. Milestones

| # | Milestone | Exit criterion |
|---|---|---|
| 0 | Oracle harness: Ruby driver, op language, comparator (with the reader extensions it needs), negative controls, `scripts/check.mbtx`; enable the js target (packages declare `native+wasm` today) or record why not | seed scripts compare clean twice in a row; every negative control fails |
| 1 | Output integration (§1) designed and upstreamed; `Document` core: page setup, margins, cursor, bounding/column boxes, `move_down`/`pad`/`float`, page navigation | bounding_box/column_box/document specs as op scripts |
| 2 | Text: `text`, `text_box`, `formatted_text`, inline format, `draw_text`, overflow modes (truncate, shrink_to_fit, expand), alignment/valign, leading, spacing, rotation, fragment and draw-text callbacks; std-14 AFM with kerning; TTF fonts and fallback fonts as the text specs use them | text specs (incl. the mixed AFM/TTF fallback ones) and manual text section |
| 3 | Graphics: paths, shapes, colours (RGB/CMYK), stroke styles, transformations, transparency, soft masks, gradients | graphics specs and manual |
| 4 | Fonts in full: OTF/CFF, TTC, dfont, subsetting quality, kerning; rerun the whole text suite | font specs; text suite still clean |
| 5 | Images: PNG (all types, transparency), JPEG; inline images | images specs |
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
