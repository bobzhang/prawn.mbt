///|
// The fragments of formatted text and their character formatting (Prawn's
// formatted text hashes, with the keys asciidoctor-pdf adds).

///|
using @pagelayout {type Color}

///|
/// Character formatting of a fragment.
pub(all) struct Style {
  family : String
  size : Double
  bold : Bool
  italic : Bool
  color : Color
  /// where the text links to, as Prawn draws it: `<a anchor>` jumps to a
  /// named destination, `<a href>` is a URI action even when the URI is
  /// only a fragment (`link:#name[]`)
  link : @pagelayout.LinkTarget?
  background : Color?
  /// 1 for superscript, -1 for subscript (Prawn raises a superscript by 0.85
  /// of its ascender and drops a subscript by its descender)
  script : Int
  /// padding around the text inside its background (mark, kbd): widens the
  /// fragment by twice this, as asciidoctor-pdf's `border_offset` does
  border_offset : Double
  underline : Bool
  strike : Bool
  /// a word joiner (`class="wj"`, a footnote's label): the word before it
  /// must fit on its line together with it
  wj : Bool
  /// an inline image (the index of its `InlineImage` in the session), set
  /// as a placeholder as wide as the image; -1 for text
  image : Int
  /// the document's callback for the fragment (Prawn's fragment `callback`):
  /// `Hooks::fragment_inked` learns when a run in this style is inked on a
  /// page outside dry runs; -1 for none
  callback : Int
  /// the style of the document font the text is set in (Prawn's current
  /// font, as `theme_font` sets it); `bold` and `italic` are the styles of
  /// the markup (and those inherited explicitly, as headings do)
  doc_bold : Bool
  doc_italic : Bool
  /// the markup names a font family (`<code>`, `<kbd>`, `<font name>`)
  font_set : Bool
  /// the theme's `text_transform` (`uppercase`, `lowercase`, `capitalize`)
  text_transform : String?
  /// how far `background` reaches in a highlighted source block (None: the
  /// glyph box)
  code_background : CodeBackground?
  /// a line number of a source block (asciidoctor-pdf's `linenum`
  /// fragments): never dropped, and no break opportunity (`SourceLineWrap`)
  linenum : Bool
  /// a zero-width mark that paints its `background` behind the rest of its
  /// line (a highlighted source line)
  line_mark : Bool
  /// a line break `source_wrap` puts where a numbered line wraps: the line
  /// it ends loses its trailing blanks and mark as a wrapped line does in
  /// Prawn, not as one a line break of the text ends
  wrap_break : Bool
} derive(Eq)

///|
/// The (bold, italic) face a fragment is set in, as Prawn's arranger picks
/// it (`apply_font_settings`): a fragment whose markup names a font or a
/// bold or italic style takes exactly those styles; any other fragment is
/// set in the document font, whatever its style.
pub fn Style::face_style(self : Style) -> (Bool, Bool) {
  if self.font_set || self.bold || self.italic {
    (self.bold, self.italic)
  } else {
    (self.doc_bold, self.doc_italic)
  }
}

///|
/// A run of text in one style. An `anchor` fragment has no text and marks
/// a named destination at its position.
pub(all) struct Fragment {
  text : String
  style : Style
  anchor : String?
}

///|
pub extend Style with Eq::{not_equal, equal}
