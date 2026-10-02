# Prawn → MoonBit port plan

Upstream: `.repos/prawn` (prawnpdf/prawn @ `c5be930c` = 2.5.0 + 16 commits, Ruby, ~11.8k lines in
`lib/`, 839 RSpec examples, ~100 manual example programs). Gems unpacked in `.repos/gems/`:

| gem | version | lines | role | v1 phase |
|---|---|---|---|---|
| pdf-core | 0.10.0 | 2.9k | PDF objects + serializer, object store, pages, name trees, renderer | A |
| ttfunk | 1.8.0 | 9.7k | TTF/OTF(CFF)/TTC/dfont parsing, kerning, **subset encoding** | A |
| matrix | 0.4 | – | `Matrix` multiply in the transformation stack (trivial) | A |
| prawn-table | 0.2.2 | 2.3k | tables | B |
| prawn-svg | 0.40.4 | 7.1k (+ css_parser 3.2.0 2.0k, REXML) | SVG input | B |
| prawn-icon | 4.1.0 | 0.7k + 3 MB icon fonts | icon fonts (FontAwesome, Foundation, Material, PaymentFont) | B |
| prawn-templates | 0.1.2 | 0.6k (+ pdf-reader 2.16 8.5k) | import pages of existing PDFs | B |

Reference ports: `~/git/asciidoctor.mbt` (methodology: Ruby oracle, harvest, differential tests,
Codex reviews), `~/git/office.mbt` (pdflite/pagelayout; reused and improved via PRs). The long-term
consumer is an asciidoctor-pdf port (`asciidoctor.mbt/docs/pdf-backend-guidance.md`), which needs
Prawn's cursor/bounding-box/text-box semantics exactly. Codex's review of the first draft:
`docs/plan-review-codex.md`.

## 0. Decisions (confirmed with user 2026-10-01)

| Topic | Decision |
|---|---|
| Module | `bobzhang/prawn`, repo `prawn.mbt`, git, `.repos/` ignored |
| Fidelity | **Byte-identical PDFs** vs Ruby for eligible fixtures (see §5 for the exact contract) |
| pdf-core / ttfunk | Packages of this module (`pdfcore/`, `ttfunk/`), shaped like the Ruby so Prawn ports line by line. Generic capabilities go to office.mbt as PRs |
| Scope | Prawn + pdf-core + ttfunk (phase A), then prawn-table, prawn-svg, prawn-icon, prawn-templates (phase B), with early integration spikes for each |
| office.mbt | Reuse narrowly (§3); bugs/gaps fixed upstream with focused PRs to `moonbitlang/office.mbt` |
| Review | Codex CLI (`model_reasoning_effort=high`, read-only) reviews the plan, each milestone's architecture, and the API before release; reviews saved under `docs/` |

Version note: asciidoctor-pdf pins `prawn ~> 2.4.0`, `prawn-svg ~> 0.38.0`, `prawn-icon ~> 3.1.0`.
Prawn 2.4→2.5 changes in `lib/` are mostly documentation and small fixes; we port the checkout
(2.5.0+) and the latest companion releases, and record any behavior the asciidoctor-pdf port needs
from the older pins when we get there.

## 1. Architecture

* **Direct pdf-core emission.** This compatibility backend produces bytes through a port of
  pdf-core, not through pagelayout's IR + pdflite emitter. This supersedes, for the Prawn layer, the
  "record pagelayout IR" recommendation in `pdf-backend-guidance.md`: only one of them can own the
  output bytes, and byte parity requires pdf-core's. Reusable measurement/geometry contracts can be
  shared with pagelayout later.
* **One root package for Prawn** (at the module root, imported as `bobzhang/prawn`). `Document` mixes
  in ~15 Ruby modules that call each other freely, and `Font`/`BoundingBox`/`Text::Box` hold
  document back-pointers, so splitting creates cycles. Many cohesive files, not necessarily Ruby's
  file boundaries. `pdfcore` and `ttfunk` sit below it with no back-dependencies.
* **Synchronous, pure core.** Fonts/images/SVG/PDF templates are passed as bytes or resolved through
  an `AssetLoader` trait over **preloaded** assets. No rerun-on-miss fixpoint (unlike asciidoctor's
  io): drawing closures and callbacks have side effects. `io/` (moonbitlang/async) preloads files
  and writes output (`render_file`, `generate(path)`).
* **Ruby idioms → MoonBit**
  - option hashes → labeled optional params; internally typed option records that preserve
    "unset/inherit" vs explicit `false`/`0`, resolved at the same stage as Ruby (formatted boxes
    inherit direction, spacing, kerning from document state — `text/formatted/box.rb:186`);
  - `generate { … }` / `instance_eval` / `bounding_box { … }` / `float` / `repeat` / `stamp` /
    `transparent` → closures `(Document) -> Unit raise`, with specified state restoration on error
    and across page changes; repeater/page hooks get explicit lifetime/ordering contracts;
  - `Prawn::View` → composition: a trait with a `document()` accessor and default methods
    forwarding to it (Ruby's `method_missing` has no analogue; the forwarded set is explicit);
  - formatted-text fragments → `Fragment` record; callbacks → ordered `FragmentCallback` trait
    objects with underlay/overlay phases and draw-text replacement, suppressed during dry runs
    (`box.rb:332`);
  - Text box extension points → **explicit policy hooks** that asciidoctor-pdf overrides (fallback
    font selection, justification, vertical alignment, decoration, wrap configuration — see
    `asciidoctor-pdf/lib/asciidoctor/pdf/ext/prawn/formatted_text/box.rb`), plus rich layout results
    (consumed fragments, remainder, line metrics) and a supported scratch/checkpoint mechanism
    instead of Ruby Marshal cloning (`ext/prawn/extensions.rb:958`);
  - exceptions → `suberror PrawnError { CannotFit, UnknownFont, IncompatibleStringEncoding, … }`;
    `Prawn.debug = true` option verification → validation errors.
* **Strings.** Unicode text is scanned by scalar (never split surrogates); AFM fonts transcode to
  Windows-1252 **bytes** and lay out on bytes (`fonts/afm.rb:141`, `:301`); binary data is `Bytes`.
* ~15 regexes (inline-format tokenizer, line-wrap scanning, AFM lines) → hand-written scanners
  with differential tests. No regex engine dependency.

## 2. Package layout

```
moon.mod                      bobzhang/prawn
*.mbt (root package)          Prawn: Document + mixins, fonts (AFM/TTF/TTC/DFont/OTF), metric cache,
                              ToUnicode CMap, text + Text::Formatted::{Parser,Arranger,LineWrap,Wrap,
                              Fragment,Box}, BoundingBox/ColumnBox/Span, Grid, Repeater, Stamp,
                              Outline, Security, SoftMask, TransformationStack, Graphics (color, dash,
                              cap/join, blend, transparency, patterns, transformation), Images
                              (PNG, JPG, handler), Measurements, View
internal/rb/                  Ruby compat: Float#to_s, format('%.5f') exact rounding, Integer floor
                              div/mod, round/ceil/floor, Windows-1252 encode (+errors), pack/unpack,
                              32/64-bit wrapping arithmetic, SHA1 hex
pdfcore/                      pdf-core port (PdfValue, pdf_object, real, Reference, Stream, Filters,
                              ObjectStore, DocumentState, Page, PageGeometry, NameTree, Outline,
                              Annotations, Destinations, GraphicsState, Renderer, Text)
ttfunk/                       ttfunk port (File, Collection, ResourceFile, tables, CFF, Subset::*,
                              TTF/OTF encoders, BinUtils, Placeholder)
table/                        prawn-table            (phase B)
svg/  internal/css/           prawn-svg, css_parser  (phase B)
icon/  icon/data/             prawn-icon             (phase B; font packs optional)
templates/                    prawn-templates on the pdflite reader (phase B)
io/                           async preload/write
inspector/                    PDF::Inspector equivalent for tests, on pdflite's reader
cmd/oracle/                   op-script interpreter (§5)
cmd/golden/                   harvested-PDF replay runner
scripts/                      harvest.mbtx, oracle Ruby driver, generators/shrinker, check.mbtx
tests/                        op scripts, goldens, known_failures.txt, record counts
data/                         Prawn's AFM files (embedded as constants so std-14 fonts work on wasm),
                              test fonts/images (licenses recorded)
```

## 3. Reuse from office.mbt (verified against current APIs)

pdflite's writer does not match pdf-core (12-significant-digit reals, unsorted one-line dicts,
different string/name escaping, own xref/trailer), so serialization is ported from pdf-core.

| Piece | Decision |
|---|---|
| Inflate/deflate | Reuse `pdflite/flate` (`pdf_flate_decode_view`, `pdf_flate_encode_view_with_level`). Exact zlib reproduction is an optional later project |
| Encryption | Reuse MD5, RC4, padding, qualified R2 entry helpers from `crypt_core`. Keep Prawn's orchestration: permissions start with all 32 bits set (pdflite follows reserved-bit conventions), Prawn's key derivation omits the file ID (`security.rb:179`) |
| AFM | PR to `pdflite/font/afm`: expose glyph-name kerning (incl. `C -1` glyphs, currently discarded) and glyph bboxes; then reuse the parser. Std-14 kerning is not a drop-in |
| PNG/JPEG | Port Prawn's small handlers. `PdfPNG` lacks transparency info, rejects translucent palettes, accepts Adam7 (Prawn rejects); JPEG API lacks bits/components. Optional PRs to pdflite for those gaps |
| TrueType | Qualify `pdf_truetype_tables/table`, metrics, loca offsets, composite expansion individually; TTFunk's subset assignment + encoder (table order, checksum adjustment, naming) ported exactly |
| PDF reading | `pdf_read_document_from_bytes`, `pdf_parse_content_ops_from_bytes` for `inspector/` (add position tracking, font decoding, form recursion) and for prawn-templates (map pdflite objects to `PdfValue`) |
| XML (prawn-svg) | Candidate: `Milky2018/xml` / `ooxml/xml`, qualified against REXML behavior (entities, whitespace, namespaces) |

## 4. Data model notes

* `PdfValue` mirrors pdf-core's `pdf_object` dispatch: nil, bool, Integer, Float, String (text →
  `<FEFF…>` UTF-16BE hex), ByteString (hex), LiteralString (`(…)`, escapes `\ ( ) \r`), Symbol
  (name), Array, Hash, Reference, Date/Time, NameTree::Node, OutlineRoot/Item.
  **Dicts serialize with keys sorted by `k.to_s`** (`pdf_object.rb:110`); insertion order still
  matters elsewhere (resource allocation, font encodings).
* Numbers: `pdf_object(1)` and `pdf_object(1.0)` both give `1`, but `real(1.0)` gives `1.0`;
  `real(-0.0)` = `-0.0`, `pdf_object(-0.0)` = `-0` (`pdf_object.rb:11`, `:82`) — separate contracts.
* `Reference`s are shared mutable cells in creation order; identity via `physical_equal`.
* Fonts: closed enum `Afm | Ttf | Otf | …` sharing a `FontBase`; one subset object per 256 glyphs.

## 5. Fidelity contract and testing

**Contract.** Three tiers, never normalizing away text positions, glyph choice or pagination:
1. *Exact bytes* for fixtures whose output involves no Flate encoding.
2. *Decoded equivalence* where Flate is involved: every PNG image stream (Prawn inflates IDAT and
   recompresses via the Flate filter, `png.rb:132`, `:216`, `filters.rb:16`), `compress: true`,
   compressed font/ToUnicode streams. Compare objects after inflating; `/Length`, xref offsets and
   `startxref` are recomputed, everything else identical.
3. *Behavioral assertions* everywhere: cursor, bounds, page number, remainder fragments, line
   metrics, callback order, errors, warnings.

Oracle environment pinned: Homebrew Ruby 4.0.7, gem versions above + rspec/pdf-reader/pdf-inspector
installed into `.repos/gems`, frozen clock/TZ/RNG (the manual uses `Time.now` and random owner
passwords: `manual/document_and_page_options/metadata.rb:26`, `manual/security/permissions.rb:44`),
pinned zlib.

**Primary investment: operation-script differential testing.** Recording rendered PDFs can't
recover the Ruby programs that made them, and many examples assert without rendering. So:
1. A JSON op language with nested scopes (bounding_box/float/column_box/repeat/stamp as nested op
   lists), explicit assets, typed numbers (Integer vs Float), **queries** (cursor, bounds,
   `width_of`, `height_of`, text box remainder, page count), callback traces, expected errors.
   Interpreted by `scripts/oracle/driver.rb` (Ruby Prawn) and `cmd/oracle` (port); outputs = PDF +
   query/trace log, compared under the contract.
2. Translate representative upstream spec examples and every manual example into op scripts once;
   replay through both implementations.
3. Seeded generators targeting boundaries: widths/heights within ε of measured values, Unicode
   scalars (combining, astral, CJK, RTL, soft hyphen, ZWSP), fallback switches, subset capacity
   (256-glyph chunks), page breaks. Shrinking; minimized failures saved as regression scripts.
   Coverage is tracked by feature × boundary, not raw case count.
4. Harvested PDFs from the RSpec run (recorder hooks `render` without forcing extra renders —
   rendering runs repeaters and finalizes pages, `document.rb:456`, `renderer.rb:192`) as extra
   evidence; hand-port only examples that need mocks, extensions, or object identity.
5. Unit differential tests for pure pieces: `real`/`pdf_object`, Float#to_s, Windows-1252, inline
   tokenizer, line-wrap scanning, ttfunk tables and subset bytes per test font, ToUnicode CMaps.
6. pdf-core's and ttfunk's own **test suites** (fetched from their pinned git tags — the gems ship
   no specs) ported for those packages.
7. Gates exit non-zero on unexpected differences; record counts guarded; `scripts/check.mbtx` runs
   everything; tests on native, wasm-gc, js.

## 6. Milestones (ordered by layout risk)

| # | Milestone | Exit criterion |
|---|---|---|
| 0 | Scaffold, git, pinned oracle env, op language + Ruby driver, pdf-core/ttfunk test repos, check script | Ruby driver runs the seed scripts deterministically twice |
| 1 | `internal/rb` + `pdfcore` (serializer, store, renderer, pages) | pdf-core specs; empty and hello-world documents byte-identical |
| 2 | AFM fonts + text measurement; Text::Box, Formatted::{Parser, Arranger, LineWrap, Wrap, Fragment, Box}; dry runs; overflow/remainder; page transitions; bounding boxes, column box, cursor | text/box/line_wrap/arranger/parser specs as op scripts; boundary fuzz identical |
| 3 | One TTF path end-to-end (ttfunk TTF subset + encoder, Prawn TTF font, ToUnicode, kerning, fallback fonts) + an asciidoctor-pdf-shaped integration scenario (justified multipage text near a page boundary, decorated split block, link) | subset bytes identical for test TTFs; integration scenario identical |
| 4 | Graphics, colors, transformations, transparency, blend, soft masks, patterns/gradients; asset loader + `io/`; API review (Codex) | graphics specs + manual graphics/basic_concepts/bounding_box/layout sections |
| 5 | Images (PNG all color types/bit depths/transparency, JPG) + fragment callbacks/inline images | images specs (decoded tier) |
| 6 | Navigation and page hooks: outline, destinations, annotations, links, page labels/numbering, repeaters, stamps, grid, view | remaining specs; manual text/outline/repeatable_content sections |
| 7 | Remaining fonts: TTC, dfont, OTF/CFF (ttfunk CFF encoder) | font specs; CFF subset bytes identical |
| 8 | Security (RC4 40-bit, R2) | security specs; manual security section |
| 9 | Full manual byte/decoded identical; README.mbt.md; release prep; Codex architecture review | publish `bobzhang/prawn` |
| 10 | prawn-table (spike already after M3) | prawn-table specs + manual |
| 11 | prawn-templates on pdflite reader (spike after M6) | template specs (decoded tier) |
| 12 | prawn-icon (+ optional font-pack packages to bound binary size) | specs |
| 13 | prawn-svg + css_parser + XML (spike after M5) | prawn-svg specs + its sample SVGs |
| – | Performance (from M2 on: fallback scanning, repeated dry runs); optional exact zlib deflate | benchmarks in status log |

## 7. Pitfalls checklist

* `real()` vs `pdf_object()` number formatting (§4); correctly rounded `%.5f` from the exact binary
  value; keep Ruby's floating-point operation order everywhere.
* Ruby Integer vs Float semantics: `/` and `%` floor, `round` half away from zero, `Float#floor`
  returning Integer, `1` vs `1.0` in `to_s` (gradient keys hash Ruby float strings,
  `graphics/patterns.rb:292`).
* Transcendental functions in rotations (`graphics/transformation.rb:39`): check native/wasm/js
  agree with Ruby's libm on test angles.
* Explicit integer widths: permissions `4294967295` (`security.rb:140`), 64-bit LONGDATETIME
  (`ttfunk/table/head.rb:92`), wrapping 32-bit checksums.
* Omitted owner password = user password (`security.rb:78`); only `:random` uses `rand`.
  Encrypted trailers get no automatic `/ID` (`renderer.rb:265`).
* Font subset tag = `SHA1(key)[0,6]` (`ttfunk/table/name.rb:188`).
* Hash insertion order where it is observable (resources, encodings); sorted keys in output dicts.
* Malformed inputs (bad encodings, truncated images/fonts) must fail like Ruby; record any
  intentional deviation in a compatibility-limits section.

## 8. Open questions from the import

The module now starts from the layout code factored out of asciidoctor.mbt's PDF backend
(published as `bobzhang/prawn` 0.1.0, consumed by `bobzhang/asciidoctor-pdf` 0.2.0). That code
measures and wraps like Prawn but draws through pagelayout/pdflite, while §1 has pdf-core own the
bytes. To settle before milestone 1:

* **Path from 0.1.0 to §1.** Grow the existing `Flow`/`typeset`/`FontCatalog` API toward Prawn's
  `Document` with pdf-core emission as a second backend, or start the root package fresh and keep
  0.1.0's API as a compatibility layer until asciidoctor-pdf switches. asciidoctor-pdf
  depends on the published API, so breaking changes need a minor version bump and a matching
  asciidoctor-pdf release.
* **Licence.** Prawn, pdf-core and TTFunk are under Ruby's licence / GPLv2 / GPLv3, so a
  line-by-line port cannot simply be MIT. 0.1.0 keeps adapted parts under Matz's terms with a
  NOTICE (`NOTICE`, `LICENSES/LICENSE-prawn`).
* **Versions.** §0 targets Prawn 2.5 / prawn-svg 0.40; asciidoctor-pdf 2.3.27 (the consumer's
  oracle) pins Prawn 2.4.0, and `svg/` ports prawn-svg 0.34.2.
* **0.1.0 API cleanup** (carried over from asciidoctor.mbt's TODO): move converter-only
  `Style.text_transform` and `default_font_files` back to asciidoctor-pdf; stop exposing
  `build_items`/`Item` (public only for a white-box test there); `Flow` is `pub(all)` for now.
* **SVG regression coverage** (Codex nit on asciidoctor.mbt#7): SVG under different documents'
  font scopes; bounds-dependent SVG in a section title loaded after a differently sized document.

## 9. Status log

* 2026-10-02: imported `prawn/` from asciidoctor.mbt with its history (46 tests pass standalone).
