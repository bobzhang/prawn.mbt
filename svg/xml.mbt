///|
// A small, lenient XML reader for SVG documents: elements with their
// attributes (qualified names as written), text and CDATA; character and
// entity references, including entities declared in the DOCTYPE's internal
// subset (as Illustrator writes them), are expanded. Namespaces are
// resolved for elements only, which is what prawn-svg (via REXML) looks at.

///|
/// An element: its local name, the namespace_uri URI its prefix (or the default
/// namespace_uri) is bound to ("" when none is), its attributes in document
/// order and its children.
pub struct Element {
  name : String
  mut namespace_uri : String
  attributes : Array[(String, String)]
  children : Array[XmlNode]
  priv mut parent : Element?
  /// unique within its document (shared by shallow copies)
  priv uid : Int
}

///|
/// A child of an element.
pub enum XmlNode {
  Elem(Element)
  Text(String)
  CData(String)
}

///|
/// The value of the attribute written `name` (prefix included).
pub fn Element::attr(self : Element, name : String) -> String? {
  for pair in self.attributes {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The child elements, in order.
pub fn Element::elements(self : Element) -> Array[Element] {
  let out = []
  for child in self.children {
    if child is Elem(e) {
      out.push(e)
    }
  }
  out
}

///|
pub fn Element::parent(self : Element) -> Element? {
  self.parent
}

///|
/// Every element of the tree rooted here, in document order.
pub fn Element::descendants(self : Element) -> Array[Element] {
  let out = []
  let stack = [self]
  while stack.pop() is Some(e) {
    out.push(e)
    let kids = e.elements()
    for j = kids.length() - 1; j >= 0; j = j - 1 {
      stack.push(kids[j])
    }
  }
  out
}

///|
/// The text of the element's text and CDATA children, concatenated.
pub fn Element::text(self : Element) -> String {
  let sb = StringBuilder()
  for child in self.children {
    match child {
      Text(t) | CData(t) => sb.write_string(t)
      Elem(_) => ()
    }
  }
  sb.to_string()
}

///|
/// A deep copy of the element (detached from its parent).
pub fn Element::copy(self : Element) -> Element {
  let e = Element::{
    name: self.name,
    namespace_uri: self.namespace_uri,
    attributes: self.attributes.copy(),
    children: [],
    parent: self.parent,
    uid: self.uid,
  }
  for child in self.children {
    match child {
      Elem(c) => {
        let copied = c.copy()
        copied.parent = Some(e)
        e.children.push(Elem(copied))
      }
      other => e.children.push(other)
    }
  }
  e
}

///|
/// Set (or add) an attribute.
pub fn Element::set_attr(self : Element, name : String, value : String) -> Unit {
  for i, pair in self.attributes {
    if pair.0 == name {
      self.attributes[i] = (name, value)
      return
    }
  }
  self.attributes.push((name, value))
}

///|
/// Why a document is not XML.
pub suberror XmlError {
  XmlError(String)
}

///|
priv struct XmlReader {
  text : String
  mut pos : Int
  entities : Map[String, String]
  mut count : Int
  /// how many elements the one being read is inside
  mut depth : Int
}

///|
/// The deepest element nesting a document may have (the root is at depth
/// 1). Reading, copying, drawing and lowering an SVG are all recursive
/// over its tree; REXML itself has no limit, but prawn-svg's recursion
/// runs out of Ruby stack long before the input does.
let max_xml_depth : Int = 256

///|
/// The most bytes the references of one text or attribute value may expand
/// to (REXML's `Security.entity_expansion_text_limit`).
let entity_expansion_text_limit : Int = 10240

///|
/// The number of bytes `s` takes in UTF-8.
fn utf8_size(s : String) -> Int {
  let mut n = 0
  for ch in s {
    let c = ch.to_int()
    n += if c < 0x80 {
      1
    } else if c < 0x800 {
      2
    } else if c < 0x10000 {
      3
    } else {
      4
    }
  }
  n
}

///|
fn XmlReader::peek(self : XmlReader, offset? : Int = 0) -> Int {
  let i = self.pos + offset
  if i < self.text.length() {
    self.text[i].to_int()
  } else {
    -1
  }
}

///|
fn XmlReader::starts(self : XmlReader, prefix : String) -> Bool {
  let n = prefix.length()
  if self.pos + n > self.text.length() {
    return false
  }
  for i in 0..<n {
    if self.text[self.pos + i] != prefix[i] {
      return false
    }
  }
  true
}

///|
fn XmlReader::skip_until(
  self : XmlReader,
  marker : String,
) -> String raise XmlError {
  let start = self.pos
  while self.pos < self.text.length() {
    if self.starts(marker) {
      let content = self.text.unsafe_substring(start~, end=self.pos)
      self.pos += marker.length()
      return content
    }
    self.pos += 1
  }
  raise XmlError("unterminated construct, expected \{marker}")
}

///|
fn is_space(c : Int) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn XmlReader::skip_space(self : XmlReader) -> Unit {
  while is_space(self.peek()) {
    self.pos += 1
  }
}

///|
fn is_name_char(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == ':' ||
  c == '-' ||
  c == '.' ||
  c >= 0x80
}

///|
fn XmlReader::name(self : XmlReader) -> String raise XmlError {
  let start = self.pos
  while self.peek() >= 0 && is_name_char(self.peek()) {
    self.pos += 1
  }
  if self.pos == start {
    raise XmlError("expected a name at offset \{start}")
  }
  self.text.unsafe_substring(start~, end=self.pos)
}

///|
/// Expand character and entity references. As REXML's
/// `Text.unnormalize`, the expansions of one value may total at most
/// `entity_expansion_text_limit` bytes; an entity's own expansion is cut
/// short as soon as it exceeds that, so that nested entities cannot blow
/// up first.
fn XmlReader::expand(
  self : XmlReader,
  raw : String,
  depth? : Int = 0,
) -> String raise XmlError {
  guard raw.contains("&") else { return raw }
  let too_large = XmlError("entity expansion has grown too large")
  let sb = StringBuilder()
  let n = raw.length()
  let mut sum = 0
  let mut i = 0
  while i < n {
    let c = raw[i]
    if c == '&' {
      let mut j = i + 1
      while j < n && raw[j] != ';' && j - i < 64 {
        j += 1
      }
      if j < n && raw[j] == ';' {
        let name = raw.unsafe_substring(start=i + 1, end=j)
        let character = fn(digits : String, base : Int) -> String? {
          let code = @string.parse_int(digits, base~) catch { _ => -1 }
          code.to_char().map(ch => ch.to_string())
        }
        let replacement : String? = if name.has_prefix("#x") ||
          name.has_prefix("#X") {
          character(name.unsafe_substring(start=2, end=name.length()), 16)
        } else if name.has_prefix("#") {
          character(name.unsafe_substring(start=1, end=name.length()), 10)
        } else {
          match name {
            "lt" => Some("<")
            "gt" => Some(">")
            "amp" => Some("&")
            "quot" => Some("\"")
            "apos" => Some("'")
            _ =>
              match self.entities.get(name) {
                Some(value) =>
                  Some(
                    if depth < 8 {
                      self.expand(value, depth=depth + 1)
                    } else {
                      value
                    },
                  )
                None => None
              }
          }
        }
        match replacement {
          Some(r) => {
            sum += utf8_size(r)
            if sum > entity_expansion_text_limit {
              raise too_large
            }
            sb.write_string(r)
            i = j + 1
            continue
          }
          None => ()
        }
      }
    }
    sb.write_char(c.unsafe_to_char())
    i += 1
  }
  sb.to_string()
}

///|
/// The DOCTYPE, recording the entities of its internal subset.
fn XmlReader::doctype(self : XmlReader) -> Unit raise XmlError {
  // after `<!DOCTYPE`
  while self.pos < self.text.length() {
    let c = self.peek()
    if c == '>' {
      self.pos += 1
      return
    } else if c == '[' {
      self.pos += 1
      // the internal subset
      while self.pos < self.text.length() {
        self.skip_space()
        if self.peek() == ']' {
          self.pos += 1
          break
        } else if self.starts("<!ENTITY") {
          self.pos += 8
          self.skip_space()
          let parameter = self.peek() == '%'
          if parameter {
            self.pos += 1
            self.skip_space()
          }
          let name = self.name()
          self.skip_space()
          let quote = self.peek()
          if quote == '"' || quote == '\'' {
            self.pos += 1
            let value = self.skip_until(if quote == '"' { "\"" } else { "'" })
            if !parameter {
              self.entities[name] = value
            }
          }
          ignore(self.skip_until(">"))
        } else if self.starts("<!--") {
          self.pos += 4
          ignore(self.skip_until("-->"))
        } else if self.starts("<") {
          ignore(self.skip_until(">"))
        } else {
          self.pos += 1
        }
      }
    } else if c == '"' || c == '\'' {
      self.pos += 1
      ignore(self.skip_until(if c == '"' { "\"" } else { "'" }))
    } else {
      self.pos += 1
    }
  }
}

///|
/// The namespace_uri URI `prefix` is bound to on `element` or its ancestors
/// (`xmlns` / `xmlns:prefix` declarations); "" when unbound.
fn namespace_of(element : Element, prefix : String) -> String {
  let key = if prefix == "" { "xmlns" } else { "xmlns:" + prefix }
  let mut current : Element? = Some(element)
  while current is Some(e) {
    match e.attr(key) {
      Some(uri) => return uri
      None => current = e.parent
    }
  }
  match prefix {
    "xml" => "http://www.w3.org/XML/1998/namespace_uri"
    _ => ""
  }
}

///|
fn XmlReader::element(
  self : XmlReader,
  parent : Element?,
) -> Element raise XmlError {
  // after `<`
  if self.depth >= max_xml_depth {
    raise XmlError("elements are nested more than \{max_xml_depth} deep")
  }
  self.depth += 1
  defer {
    self.depth -= 1
  }
  let qname = self.name()
  let attributes = []
  let mut self_closing = false
  for ;; {
    self.skip_space()
    let c = self.peek()
    if c == '/' && self.peek(offset=1) == '>' {
      self.pos += 2
      self_closing = true
      break
    } else if c == '>' {
      self.pos += 1
      break
    } else if c < 0 {
      raise XmlError("unterminated start tag <\{qname}>")
    }
    let name = self.name()
    self.skip_space()
    if self.peek() != '=' {
      raise XmlError("attribute \{name} of <\{qname}> has no value")
    }
    self.pos += 1
    self.skip_space()
    let quote = self.peek()
    if quote != '"' && quote != '\'' {
      raise XmlError("unquoted attribute value for \{name}")
    }
    self.pos += 1
    let raw = self.skip_until(if quote == '"' { "\"" } else { "'" })
    // attribute value normalization: whitespace characters become spaces
    let normalized = if raw.contains_any(chars="\t\n\r") {
      String::from_iter(
        raw
        .iter()
        .map(ch => if ch == '\t' || ch == '\n' || ch == '\r' { ' ' } else { ch }),
      )
    } else {
      raw
    }
    attributes.push((name, self.expand(normalized)))
  }
  let (prefix, local_name) = match qname.find(":") {
    Some(i) =>
      (
        qname.unsafe_substring(start=0, end=i),
        qname.unsafe_substring(start=i + 1, end=qname.length()),
      )
    None => ("", qname)
  }
  let element = Element::{
    name: local_name,
    namespace_uri: "",
    attributes,
    children: [],
    parent,
    uid: {
      self.count += 1
      self.count
    },
  }
  element.namespace_uri = namespace_of(element, prefix)
  if self_closing {
    return element
  }
  let text = StringBuilder()
  let flush = fn() raise XmlError {
    if !text.is_empty() {
      element.children.push(Text(self.expand(text.to_string())))
      text.reset()
    }
  }
  for ;; {
    if self.pos >= self.text.length() {
      raise XmlError("unterminated element <\{qname}>")
    }
    if self.starts("</") {
      flush()
      self.pos += 2
      let closing = self.name()
      self.skip_space()
      if self.peek() != '>' {
        raise XmlError("malformed end tag </\{closing}")
      }
      self.pos += 1
      if closing != qname {
        raise XmlError("mismatched end tag </\{closing}> for <\{qname}>")
      }
      return element
    } else if self.starts("<!--") {
      flush()
      self.pos += 4
      ignore(self.skip_until("-->"))
    } else if self.starts("<![CDATA[") {
      flush()
      self.pos += 9
      element.children.push(CData(self.skip_until("]]>")))
    } else if self.starts("<?") {
      flush()
      ignore(self.skip_until("?>"))
    } else if self.peek() == '<' {
      flush()
      self.pos += 1
      element.children.push(Elem(self.element(Some(element))))
    } else {
      text.write_char(self.text[self.pos].unsafe_to_char())
      self.pos += 1
    }
  }
}

///|
/// Parse a document, returning its root element.
pub fn parse_xml(text : String) -> Element raise XmlError {
  let reader = XmlReader::{ text, pos: 0, entities: {}, count: 0, depth: 0, }
  // a byte order mark
  if reader.peek() == 0xFEFF {
    reader.pos += 1
  }
  for ;; {
    reader.skip_space()
    if reader.pos >= text.length() {
      raise XmlError("no root element")
    }
    if reader.starts("<?") {
      ignore(reader.skip_until("?>"))
    } else if reader.starts("<!--") {
      reader.pos += 4
      ignore(reader.skip_until("-->"))
    } else if reader.starts("<!DOCTYPE") {
      reader.pos += 9
      reader.doctype()
    } else if reader.peek() == '<' {
      reader.pos += 1
      let root = reader.element(None)
      // anything but comments, processing instructions and space after the
      // root is an error for REXML too
      for ;; {
        reader.skip_space()
        if reader.pos >= text.length() {
          break
        } else if reader.starts("<!--") {
          reader.pos += 4
          ignore(reader.skip_until("-->"))
        } else if reader.starts("<?") {
          ignore(reader.skip_until("?>"))
        } else {
          raise XmlError("content after the root element")
        }
      }
      return root
    } else {
      raise XmlError("text before the root element")
    }
  }
}
