///|
// The PDF standard fonts (Helvetica, Times, Courier), which Prawn uses
// when a theme names them without a font catalog entry (the base theme,
// and the Courier of a theme that does not extend the default): their AFM
// metrics (pdflite's copy of Adobe's), WinAnsi-encoded text, and nothing
// embedded (pagelayout declares them by name).

///|
/// Prawn's built-in families (`Font::AFM` via `font_families`): family →
/// the fonts of its normal, bold, italic and bold italic styles.
let standard_families : Array[(String, Array[String])] = [
  (
    "Helvetica",
    [
      "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    ],
  ),
  (
    "Times-Roman",
    ["Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic"],
  ),
  (
    "Courier",
    ["Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"],
  ),
]

///|
/// WinAnsi (`Encoding::WinAnsi::CHARACTERS`): the glyph name of each code
/// from 0x20, and the character it stands for.
let winansi_glyphs : Array[(String, Int)] = [
  ("space", 0x20),
  ("exclam", 0x21),
  ("quotedbl", 0x22),
  ("numbersign", 0x23),
  ("dollar", 0x24),
  ("percent", 0x25),
  ("ampersand", 0x26),
  ("quotesingle", 0x27),
  ("parenleft", 0x28),
  ("parenright", 0x29),
  ("asterisk", 0x2A),
  ("plus", 0x2B),
  ("comma", 0x2C),
  ("hyphen", 0x2D),
  ("period", 0x2E),
  ("slash", 0x2F),
  ("zero", 0x30),
  ("one", 0x31),
  ("two", 0x32),
  ("three", 0x33),
  ("four", 0x34),
  ("five", 0x35),
  ("six", 0x36),
  ("seven", 0x37),
  ("eight", 0x38),
  ("nine", 0x39),
  ("colon", 0x3A),
  ("semicolon", 0x3B),
  ("less", 0x3C),
  ("equal", 0x3D),
  ("greater", 0x3E),
  ("question", 0x3F),
  ("at", 0x40),
  ("A", 0x41),
  ("B", 0x42),
  ("C", 0x43),
  ("D", 0x44),
  ("E", 0x45),
  ("F", 0x46),
  ("G", 0x47),
  ("H", 0x48),
  ("I", 0x49),
  ("J", 0x4A),
  ("K", 0x4B),
  ("L", 0x4C),
  ("M", 0x4D),
  ("N", 0x4E),
  ("O", 0x4F),
  ("P", 0x50),
  ("Q", 0x51),
  ("R", 0x52),
  ("S", 0x53),
  ("T", 0x54),
  ("U", 0x55),
  ("V", 0x56),
  ("W", 0x57),
  ("X", 0x58),
  ("Y", 0x59),
  ("Z", 0x5A),
  ("bracketleft", 0x5B),
  ("backslash", 0x5C),
  ("bracketright", 0x5D),
  ("asciicircum", 0x5E),
  ("underscore", 0x5F),
  ("grave", 0x60),
  ("a", 0x61),
  ("b", 0x62),
  ("c", 0x63),
  ("d", 0x64),
  ("e", 0x65),
  ("f", 0x66),
  ("g", 0x67),
  ("h", 0x68),
  ("i", 0x69),
  ("j", 0x6A),
  ("k", 0x6B),
  ("l", 0x6C),
  ("m", 0x6D),
  ("n", 0x6E),
  ("o", 0x6F),
  ("p", 0x70),
  ("q", 0x71),
  ("r", 0x72),
  ("s", 0x73),
  ("t", 0x74),
  ("u", 0x75),
  ("v", 0x76),
  ("w", 0x77),
  ("x", 0x78),
  ("y", 0x79),
  ("z", 0x7A),
  ("braceleft", 0x7B),
  ("bar", 0x7C),
  ("braceright", 0x7D),
  ("asciitilde", 0x7E),
  (".notdef", 0),
  ("Euro", 0x20AC),
  (".notdef", 0),
  ("quotesinglbase", 0x201A),
  ("florin", 0x0192),
  ("quotedblbase", 0x201E),
  ("ellipsis", 0x2026),
  ("dagger", 0x2020),
  ("daggerdbl", 0x2021),
  ("circumflex", 0x02C6),
  ("perthousand", 0x2030),
  ("Scaron", 0x0160),
  ("guilsinglleft", 0x2039),
  ("OE", 0x0152),
  (".notdef", 0),
  ("Zcaron", 0x017D),
  (".notdef", 0),
  (".notdef", 0),
  ("quoteleft", 0x2018),
  ("quoteright", 0x2019),
  ("quotedblleft", 0x201C),
  ("quotedblright", 0x201D),
  ("bullet", 0x2022),
  ("endash", 0x2013),
  ("emdash", 0x2014),
  ("tilde", 0x02DC),
  ("trademark", 0x2122),
  ("scaron", 0x0161),
  ("guilsinglright", 0x203A),
  ("oe", 0x0153),
  (".notdef", 0),
  ("zcaron", 0x017E),
  ("Ydieresis", 0x0178),
  ("space", 0xA0),
  ("exclamdown", 0xA1),
  ("cent", 0xA2),
  ("sterling", 0xA3),
  ("currency", 0xA4),
  ("yen", 0xA5),
  ("brokenbar", 0xA6),
  ("section", 0xA7),
  ("dieresis", 0xA8),
  ("copyright", 0xA9),
  ("ordfeminine", 0xAA),
  ("guillemotleft", 0xAB),
  ("logicalnot", 0xAC),
  ("hyphen", 0xAD),
  ("registered", 0xAE),
  ("macron", 0xAF),
  ("degree", 0xB0),
  ("plusminus", 0xB1),
  ("twosuperior", 0xB2),
  ("threesuperior", 0xB3),
  ("acute", 0xB4),
  ("mu", 0xB5),
  ("paragraph", 0xB6),
  ("periodcentered", 0xB7),
  ("cedilla", 0xB8),
  ("onesuperior", 0xB9),
  ("ordmasculine", 0xBA),
  ("guillemotright", 0xBB),
  ("onequarter", 0xBC),
  ("onehalf", 0xBD),
  ("threequarters", 0xBE),
  ("questiondown", 0xBF),
  ("Agrave", 0xC0),
  ("Aacute", 0xC1),
  ("Acircumflex", 0xC2),
  ("Atilde", 0xC3),
  ("Adieresis", 0xC4),
  ("Aring", 0xC5),
  ("AE", 0xC6),
  ("Ccedilla", 0xC7),
  ("Egrave", 0xC8),
  ("Eacute", 0xC9),
  ("Ecircumflex", 0xCA),
  ("Edieresis", 0xCB),
  ("Igrave", 0xCC),
  ("Iacute", 0xCD),
  ("Icircumflex", 0xCE),
  ("Idieresis", 0xCF),
  ("Eth", 0xD0),
  ("Ntilde", 0xD1),
  ("Ograve", 0xD2),
  ("Oacute", 0xD3),
  ("Ocircumflex", 0xD4),
  ("Otilde", 0xD5),
  ("Odieresis", 0xD6),
  ("multiply", 0xD7),
  ("Oslash", 0xD8),
  ("Ugrave", 0xD9),
  ("Uacute", 0xDA),
  ("Ucircumflex", 0xDB),
  ("Udieresis", 0xDC),
  ("Yacute", 0xDD),
  ("Thorn", 0xDE),
  ("germandbls", 0xDF),
  ("agrave", 0xE0),
  ("aacute", 0xE1),
  ("acircumflex", 0xE2),
  ("atilde", 0xE3),
  ("adieresis", 0xE4),
  ("aring", 0xE5),
  ("ae", 0xE6),
  ("ccedilla", 0xE7),
  ("egrave", 0xE8),
  ("eacute", 0xE9),
  ("ecircumflex", 0xEA),
  ("edieresis", 0xEB),
  ("igrave", 0xEC),
  ("iacute", 0xED),
  ("icircumflex", 0xEE),
  ("idieresis", 0xEF),
  ("eth", 0xF0),
  ("ntilde", 0xF1),
  ("ograve", 0xF2),
  ("oacute", 0xF3),
  ("ocircumflex", 0xF4),
  ("otilde", 0xF5),
  ("odieresis", 0xF6),
  ("divide", 0xF7),
  ("oslash", 0xF8),
  ("ugrave", 0xF9),
  ("uacute", 0xFA),
  ("ucircumflex", 0xFB),
  ("udieresis", 0xFC),
  ("yacute", 0xFD),
  ("thorn", 0xFE),
  ("ydieresis", 0xFF),
]

///|
/// The WinAnsi code of a character, when WinAnsi has it.
fn winansi_code_of(codepoint : Int) -> Int? {
  for i, g in winansi_glyphs {
    if g.1 == codepoint && g.1 != 0 {
      return Some(0x20 + i)
    }
  }
  None
}

///|
/// AFM text (ASCII) as a string.
fn ascii_text(bytes : Bytes) -> String {
  let sb = StringBuilder()
  for b in bytes {
    sb.write_char(b.to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// A header value of AFM data (`Ascender`, `FontBBox`, ...).
fn afm_header(data : @afm.PdfAfmData, key : String) -> String? {
  for h in data.headers {
    if ascii_text(h.0) == key {
      return Some(ascii_text(h.1))
    }
  }
  None
}

///|
/// Build the face of a standard font from its AFM data, registering it in
/// `registry` under `family` (Prawn's `Font::AFM`): glyph widths by WinAnsi
/// code, the kerning pairs of the glyphs WinAnsi encodes (a name Prawn's
/// name table has twice — `space`, `hyphen`, and `ydieresis`, which it has
/// for `Ydieresis` too — kerns at its later code), ascender and descender,
/// and the line gap the font box leaves.
fn load_standard_face(
  registry : @fonts.FontRegistry,
  family : String,
  bold : Bool,
  italic : Bool,
  name : String,
) -> Face? raise {
  guard @pdflite.pdf_standard_font_of_name("/" + name) is Some(font) else {
    return None
  }
  let data = font.afm_data()
  // glyph name → width
  let widths : Map[String, Int] = Map([])
  for entry in data.char_name_widths {
    widths[ascii_text(entry.0)] = entry.1
  }
  let advances = Array::make(256, 0)
  let cmap : Map[Int, Int] = Map([])
  // the code of each glyph name (the later one for a name WinAnsi repeats)
  let code_of_name : Map[String, Int] = Map([])
  for i, glyph in winansi_glyphs {
    let code = 0x20 + i
    let (glyph_name, codepoint) = glyph
    if codepoint == 0 {
      continue
    }
    // Prawn's table names 0x9F `ydieresis` (it is `Ydieresis`): there it
    // has ydieresis's width, and Ydieresis, of no code, kerns with nothing
    let glyph_name = if code == 0x9F { "ydieresis" } else { glyph_name }
    advances[code] = widths.get(glyph_name).unwrap_or(0)
    cmap[codepoint] = code
    code_of_name[glyph_name] = code
  }
  // every pair of the AFM, by glyph name: those of the glyphs it gives no
  // code (the accented letters) too, which WinAnsi encodes
  let kern : Map[Int, Double] = Map([])
  for pair in font.kern_pairs_by_name() {
    let (left, right, amount) = pair
    match (code_of_name.get(left), code_of_name.get(right)) {
      (Some(lc), Some(rc)) => kern[(lc << 16) | rc] = amount.to_double()
      _ => ()
    }
  }
  let ascender = afm_header(data, "Ascender").map(afm_int).unwrap_or(718)
  let descender = afm_header(data, "Descender").map(afm_int).unwrap_or(-207)
  let bbox = afm_header(data, "FontBBox")
    .unwrap_or("0 0 0 0")
    .split(" ")
    .filter(s => s != "")
    .map(s => afm_int(s.to_owned()))
    .collect()
  let line_gap = if bbox.length() == 4 {
    bbox[3] - bbox[1] - (ascender - descender)
  } else {
    0
  }
  let metrics = @fonts.FaceMetrics::new(
    family~,
    bold~,
    italic~,
    units_per_em=1000,
    ascender~,
    descender~,
    line_gap~,
    advances~,
    cmap~,
  )
  // measure with the registered face: the one the renderer draws
  let metrics = registry.register_standard(
    family,
    metrics,
    standard=name,
    bold~,
    italic~,
  )
  Some({ metrics, ascender, descender, line_gap, kern, standard: true, })
}

///|
/// Prawn's `normalize_encoding` for AFM fonts, as asciidoctor-pdf patches
/// it: the text in WinAnsi, a few characters replaced by near equivalents
/// (`FALLBACK_CHARS`) and any other it lacks by `¬`.
fn winansi_text(text : String) -> String {
  let sb = StringBuilder()
  for c in text {
    let cp = c.to_int()
    match cp {
      0x200B => ()
      0x202F => sb.write_char('\u{a0}')
      0x2009 => sb.write_char(' ')
      0x2063 => sb.write_char('\u{ad}')
      0x25E6 => sb.write_char('-')
      0x25AA => sb.write_char('\u{b7}')
      // Windows-1252 has them (control characters, DEL), though WinAnsi
      // names no glyph for them: Prawn sets them as they are
      _ if cp < 0x20 || cp == 0x7F => sb.write_char(c)
      _ =>
        if winansi_code_of(cp) is Some(_) {
          sb.write_char(c)
        } else {
          sb.write_char('\u{ac}')
        }
    }
  }
  sb.to_string()
}

///|
/// An AFM header's integer, as Ruby's `String#to_i` reads it: the leading
/// decimal integer after any whitespace, else 0.
fn afm_int(s : String) -> Int {
  let mut i = 0
  while i < s.length() && (s[i] == ' ' || s[i] == '\t') {
    i += 1
  }
  let negative = i < s.length() && s[i] == '-'
  if i < s.length() && (s[i] == '-' || s[i] == '+') {
    i += 1
  }
  let mut v = 0
  while i < s.length() && s[i] >= '0' && s[i] <= '9' {
    v = v * 10 + (s[i].to_int() - '0'.to_int())
    i += 1
  }
  if negative {
    -v
  } else {
    v
  }
}
