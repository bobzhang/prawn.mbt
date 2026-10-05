# bobzhang/prawn

The layout of [Prawn](https://github.com/prawnpdf/prawn) 2.4.0, the Ruby PDF
library [Asciidoctor PDF](https://github.com/asciidoctor/asciidoctor-pdf)
2.3.27 lays documents out with, for MoonBit, drawing through
[moonbitlang/pagelayout](https://mooncakes.io/docs/moonbitlang/pagelayout).
It reproduces Prawn's measurements and decisions closely enough that
[bobzhang/asciidoctor-pdf](https://github.com/bobzhang/asciidoctor.mbt/tree/main/pdf) matches Ruby Asciidoctor PDF's
output.

| package | what it is |
| --- | --- |
| `bobzhang/prawn` | the document cursor, bounds, columns and pages (`Flow`), formatted text (`Fragment`, `Style`) and its line wrapping (`typeset_lines`, `Flow::typeset`, `Flow::typeset_box`), font metrics of TrueType and the standard AFM fonts (`FontCatalog`, `Face`) with fallback fonts and icon fonts; and `Document`, Prawn's own API as far as it is ported (pages, the cursor and bounding boxes, text and text boxes, fonts, images, graphics) |
| `bobzhang/prawn/svg` | a port of [prawn-svg](https://github.com/mogest/prawn-svg) 0.34.2: SVG documents rendered into pagelayout graphic operations |
| `bobzhang/prawn/table` | [prawn-table](https://github.com/prawnpdf/prawn-table) 0.2.2's sizing: column widths and row heights |

Where Prawn calls back into Asciidoctor PDF (its fragment callbacks for inline
images and destinations, and its font policy), a `Flow` takes `Hooks` from the
document:

```mbt nocheck
let catalog = FontCatalog::load(files)
let flow = Flow::new(catalog, setup, hooks={ ..Hooks::new(), base_family: "Noto Serif" })
flow.start_new_page()
flow.typeset(fragments, line_metrics(1.15, flow.font(style), style.size), style)
```

The module was factored out of the PDF backend in
[asciidoctor.mbt](https://github.com/bobzhang/asciidoctor.mbt), whose comparison
with Ruby Asciidoctor PDF (`scripts/pdf_compare.mbtx`) checks it end to end.
`Document` is checked against Ruby Prawn itself: operation scripts run through
both, their PDFs and answers compared (`docs/op-scripts.md` in the repository).
The goal here is a MoonBit Prawn as good as the Ruby original; [PLAN.md](https://github.com/bobzhang/prawn.mbt/blob/main/PLAN.md)
has the plan.

## License

MIT, except for the third-party material listed in [NOTICE](NOTICE): the
prawn-svg port (MIT, `svg/LICENSE`) and the parts adapted from Prawn and
prawn-table (Matz's terms for Ruby, `LICENSES/LICENSE-prawn`).
