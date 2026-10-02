///|
/// What the document does where Prawn calls back into asciidoctor-pdf: the
/// fragment callbacks it registers (InlineImageArranger and
/// InlineImageRenderer for inline images, InlineDestinationMarker for
/// anchors), and its font policy. One per document: a font catalog may be
/// shared between documents, these may not.
pub(all) struct Hooks {
  /// the family a family the catalog lacks falls back to (the theme's base
  /// font family) before Helvetica
  base_family : String
  /// a family (`family (style)`) neither the catalog nor `base_family` has
  /// was asked for; it is set in Helvetica
  unknown_font : (String) -> Unit
  /// the width and height of inline image `index` in a line `available`
  /// wide whose font is `font_height` tall, and whether it makes the line
  /// taller (more than one and a half lines tall)
  image_size : (Int, Double, Double) -> (Double, Double, Bool)
  /// the items that draw inline image `index` in `flow` with its top left
  /// corner at (`x`, `top`), `width` by `height`
  image_items : (Flow, Int, Double, Double, Double, Double) -> Array[
    @pagelayout.PageItem,
  ]
  /// a named destination was inked on page `number` (from 1), outside dry
  /// runs
  anchor_inked : (String, Int) -> Unit
}

///|
/// Hooks for a document without inline images, whose unknown fonts go
/// unreported.
pub fn Hooks::new(base_family? : String = "Helvetica") -> Hooks {
  {
    base_family,
    unknown_font: _ => (),
    image_size: (_, _, _) => (0.0, 0.0, false),
    image_items: (_, _, _, _, _, _) => [],
    anchor_inked: (_, _) => (),
  }
}

///|
/// What text is set with: the font catalog and the document's hooks.
pub(all) struct TextContext {
  catalog : FontCatalog
  hooks : Hooks
}
