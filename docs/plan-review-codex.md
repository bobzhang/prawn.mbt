The overall approach is sound, but I would revise the fidelity contract and move consumer-facing text semantics earlier. Several draft claims are contradicted by the pinned sources. I inspected the reference APIs and ran small, in-memory probes under Ruby 4.0.7; I modified no files and did not run the full suites.

1. **Byte-identical output is realistic for a controlled compatibility profile, not yet a universal release gate.**

   Correct these foundational claims first:

   - **Dictionary serialization is sorted**, using `k.to_s`, rather than insertion-ordered. Preserve insertion order where it affects resource allocation and font encoding, but not as the dictionary serialization rule. [pdf_object.rb:110](/Users/dii/git/prawn.mbt/.repos/gems/pdf-core-0.10.0/lib/pdf/core/pdf_object.rb:110)
   - **`pdf_object(1)` and `pdf_object(1.0)` both produce `"1"`**. `real(1.0)` produces `"1.0"`; numeric object serialization applies another trimming expression. My probe also confirmed `real(-0.0) == "-0.0"` versus `pdf_object(-0.0) == "-0"`. Test these as separate contracts. [pdf_object.rb:11](/Users/dii/git/prawn.mbt/.repos/gems/pdf-core-0.10.0/lib/pdf/core/pdf_object.rb:11), [pdf_object.rb:82](/Users/dii/git/prawn.mbt/.repos/gems/pdf-core-0.10.0/lib/pdf/core/pdf_object.rb:82)
   - **An omitted owner password is not random**: it defaults to the user password. Only `:random` invokes `rand`. Also, the ordinary encrypted trailer does **not** automatically acquire `/ID`; my probe confirmed this. [security.rb:78](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/security.rb:78), [renderer.rb:265](/Users/dii/git/prawn.mbt/.repos/gems/pdf-core-0.10.0/lib/pdf/core/renderer.rb:265)
   - **All PNG main image streams use Flate**, even with document compression disabled—not just alpha masks. Prawn inflates IDAT, then assigns a Flate filter that recompresses it. [png.rb:132](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/images/png.rb:132), [png.rb:216](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/images/png.rb:216), [filters.rb:16](/Users/dii/git/prawn.mbt/.repos/gems/pdf-core-0.10.0/lib/pdf/core/filters.rb:16)

   The manual also supplies `Time.now` and requests random passwords. Freeze clock, timezone, RNG, assets, Ruby and zlib versions in the oracle. [metadata.rb:26](/Users/dii/git/prawn.mbt/.repos/prawn/manual/document_and_page_options/metadata.rb:26), [permissions.rb:44](/Users/dii/git/prawn.mbt/.repos/prawn/manual/security/permissions.rb:44)

   Numeric compatibility extends beyond five-decimal formatting: gradients hash Ruby string representations of coordinates; transformations use transcendental functions; permissions include unsigned `4294967295`; font encoding packs 64-bit timestamps and wrapping checksums. Use explicit integer widths and test rounding boundaries across targets. [patterns.rb:292](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/graphics/patterns.rb:292), [transformation.rb:39](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/graphics/transformation.rb:39), [security.rb:140](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/security.rb:140), [head.rb:92](/Users/dii/git/prawn.mbt/.repos/gems/ttfunk-1.8.0/lib/ttfunk/table/head.rb:92)

   Adopt exact bytes for controlled, eligible fixtures; decoded object/stream equivalence for compression differences; and behavioral/layout assertions everywhere. Inflation comparison must also account for changed `/Length`, xref offsets and `startxref`. Do not normalize text positions, glyph selection or pagination away.

2. **Keep the compatibility implementation here initially; extract reusable capabilities into office.mbt deliberately.**

   One Prawn package is reasonable for mutually dependent document, box, fragment and font types. Many cohesive files are preferable to rigidly copying Ruby file boundaries. Clarify that the root package lives at the module root: `prawn/` would otherwise imply a separate import path.

   Keep `pdfcore` as the Prawn serialization/state compatibility layer. Moving it wholesale into pdflite would create two competing document models without establishing useful interoperability. Keep TTFunk’s exact encoding policy locally during parity work, while contributing independently useful font readers and encoders upstream.

   There is an unresolved architectural choice: the previous guidance recommends pagelayout IR and pdflite emission; this draft chooses direct pdf-core emission. Both cannot simultaneously determine the same output bytes. Explicitly supersede that recommendation for the compatibility backend, while preserving reusable measurement/geometry contracts for later integration. Current `layout_paragraph` returns height and lines, without bounded continuation or remainder. [pdf-backend-guidance.md:63](/Users/dii/git/asciidoctor.mbt/docs/pdf-backend-guidance.md:63), [paragraph/pkg.generated.mbti:90](/Users/dii/git/office.mbt/pagelayout/paragraph/pkg.generated.mbti:90)

3. **The reuse boundary should be narrower and more concrete.**

   | Piece | Recommendation verified against current APIs |
   |---|---|
   | Compression | Reuse `pdf_flate_decode_view` and `pdf_flate_encode_view_with_level`. Exact zlib reproduction should be optional until its value justifies the maintenance cost. [flate API:11](/Users/dii/git/office.mbt/pdflite/flate/pkg.generated.mbti:11) |
   | Encryption | Reuse MD5, RC4, padding and qualified R2 entry helpers. Keep Prawn’s orchestration and permission serialization: pdflite’s permission helper follows reserved-bit conventions, whereas Prawn starts with all 32 bits set. Its file-key helper also accepts a file ID; Prawn’s derivation omits one. [crypto API:30](/Users/dii/git/office.mbt/pdflite/crypt_core/pkg.generated.mbti:30), [permission implementation:43](/Users/dii/git/office.mbt/pdflite/crypt_core/pdf_crypt_permissions.mbt:43), [security.rb:179](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/security.rb:179) |
   | AFM | Reuse after a focused PR exposing glyph-name kerning and glyph bounding boxes. `PdfAfmData` exposes name widths but integer-code kern pairs; the parser explicitly discards pairs involving `C -1`. Prawn retains names and remaps through WinAnsi. Existing standard14 kerning is therefore not a drop-in replacement. [AFM API:19](/Users/dii/git/office.mbt/pdflite/font/afm/pkg.generated.mbti:19), [parser:174](/Users/dii/git/office.mbt/pdflite/font/afm/pdf_afm.mbt:174), [afm.rb:247](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/fonts/afm.rb:247) |
   | PNG/JPEG | Port the small Ruby handlers first. `PdfPNG` exposes no transparency information; its parser rejects translucent palettes and ignores grayscale/RGB color-key transparency. It also accepts Adam7, which Prawn rejects. JPEG’s exposed dimension functions omit bits/components; Prawn needs both and unconditionally inverts CMYK, without consulting Adobe flags. [PNG implementation:154](/Users/dii/git/office.mbt/pdflite/pdf_png.mbt:154), [Prawn PNG:188](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/images/png.rb:188), [codec API:29](/Users/dii/git/office.mbt/pdflite/codec/pkg.generated.mbti:29), [jpg.rb:70](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/images/jpg.rb:70) |
   | TrueType | Qualify `pdf_truetype_tables/table`, metrics, loca offsets and composite-glyph expansion individually. Keep TTFunk’s subset assignment and encoder: its directory order, table-data order, checksum adjustment and naming are explicit byte contracts. These functions currently live in pdflite’s root API; `font/truetype` mainly exposes types. [root API:1560](/Users/dii/git/office.mbt/pdflite/pkg.generated.mbti:1560), [ttf_encoder.rb:56](/Users/dii/git/prawn.mbt/.repos/gems/ttfunk-1.8.0/lib/ttfunk/ttf_encoder.rb:56) |
   | Inspection | Strong reuse candidate, but full entry points are root `pdf_read_document_from_bytes` and `pdf_parse_content_ops_from_bytes`. The proposed `reader/content` imports alone do not provide a complete inspector. Position tracking, font decoding and recursive form traversal still need implementation. [root API:1032](/Users/dii/git/office.mbt/pdflite/pkg.generated.mbti:1032), [root API:1148](/Users/dii/git/office.mbt/pdflite/pkg.generated.mbti:1148) |

4. **Make operation-script differential testing the primary investment.**

   Asciidoctor harvesting works because it captures replayable source and options. Recording only rendered PDFs cannot recover Prawn construction programs; hand-porting every example still leaves almost all translation work. Many examples never render: font defaults, equality, measurement and exceptions are directly asserted. [Asciidoctor PLAN:124](/Users/dii/git/asciidoctor.mbt/PLAN.md:124), [font_spec.rb:9](/Users/dii/git/prawn.mbt/.repos/prawn/spec/prawn/font_spec.rb:9)

   Build the operation language first, with nested scopes, explicit assets, typed numbers, query results, callback traces and expected failures. Translate representative upstream scenarios into that language once, then replay them through both implementations. Harvest PDFs as additional evidence; hand-port tests requiring mocks, extension behavior or object identity.

   Compare cursor/page/bounds, remainder fragments, line metrics, callback order, errors and warnings alongside PDFs. Generate boundary cases around measured widths/heights, Unicode scalars, fallback changes and subset capacity. Add shrinking and save minimized failures. “10k cases” is less useful than documented feature and boundary coverage.

   Never force extra renders during harvesting: rendering runs repeaters and finalizes page state. Preserve call order and distinguish successive renders. [document.rb:456](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/document.rb:456), [renderer.rb:192](/Users/dii/git/prawn.mbt/.repos/gems/pdf-core-0.10.0/lib/pdf/core/renderer.rb:192)

5. **Reorder milestones around layout risk.**

   After the oracle and minimal serializer, implement AFM text measurement, bounded formatted text, continuation, dry rendering and page transitions. Then add one representative TTF path and an asciidoctor-pdf-shaped integration scenario. Do not postpone all text layout until TTC, dfont and CFF are complete.

   Split milestone 6: images and fragment callbacks; navigation and page hooks; repeaters/stamps; advanced graphics; encryption. Bring asset resolution and API review forward. The synchronous-core/async-IO boundary must work before consumers depend on it.

   Acquire pinned upstream pdf-core/TTFunk **test repositories** during milestone 0: the supplied unpacked gem directories contain no spec/test suites. Treat exact deflate as an optional compatibility project. Start performance measurements when rich-text flow works, especially fallback scanning and repeated dry runs.

6. **Design explicit extension contracts, not a generic promise of Ruby extensibility.**

   Labeled optional parameters are appropriate. Preserve “inherit/default” versus explicit false/zero, and resolve defaults at Ruby’s corresponding stage: formatted boxes inherit direction, spacing and kerning from document state. [box.rb:186](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/text/formatted/box.rb:186)

   Scoped closures should accept the document and support errors; specify restoration behavior under exceptions and page changes. Deferred repeater/page hooks need explicit lifetime and execution-order contracts. Implement `Prawn::View` through composition and a document accessor; its Ruby convenience relies on `method_missing`, not a separate rendering engine. [view.rb:65](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/view.rb:65)

   Fragment callbacks need ordered collections, positioned geometry, underlay/overlay phases and draw-text replacement. Prawn suppresses painting callbacks during dry rendering. [box.rb:332](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/text/formatted/box.rb:332)

   A vaguely defined `BoxExtension` is insufficient: asciidoctor-pdf overrides fallback selection, justification, vertical alignment, decoration and wrapping configuration. Define those policy hooks explicitly. Expose rich layout results and a supported scratch/checkpoint mechanism rather than requiring public mutable internals or Marshal-style cloning. [consumer box.rb:6](/Users/dii/git/asciidoctor.mbt/.repos/asciidoctor-pdf/lib/asciidoctor/pdf/ext/prawn/formatted_text/box.rb:6), [extensions.rb:958](/Users/dii/git/asciidoctor.mbt/.repos/asciidoctor-pdf/lib/asciidoctor/pdf/ext/prawn/extensions.rb:958)

7. **Add explicit compatibility limits and integration obligations.**

   Specify malformed encodings/assets, unsupported Ruby extension patterns, repeated rendering, diagnostics, asset-cache identity, fixture licensing and per-target resource limits. Distinguish Unicode text from encoded bytes: AFM processing uses Windows-1252 bytes, so “everything scans UTF-8 code points” is incomplete. [afm.rb:141](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/fonts/afm.rb:141), [afm.rb:301](/Users/dii/git/prawn.mbt/.repos/prawn/lib/prawn/fonts/afm.rb:301)

   Finally, separate “Prawn v1 complete” from “asciidoctor-pdf ready.” Bring small table/SVG/imported-page integration spikes forward to validate extension boundaries, even if those implementations remain v2. Avoid copying Asciidoctor’s rerun-on-asset-miss strategy blindly: arbitrary drawing closures and callbacks can have side effects, so require preloaded assets or an explicit replay contract.