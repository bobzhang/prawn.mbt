///|
// Stylesheets as prawn-svg applies them: the user agent sheet (`overflow:
// hidden` on viewport elements) and every `<style>` element's rules, each
// selector turned into an XPath query in prawn-svg; here the same
// selection is made directly. An element gets the declarations of every
// rule that selects it, in order of specificity, then of appearance.

///|
priv struct AttributeTest {
  key : String
  op : String?
  value : String
}

///|
priv struct Compound {
  /// "" none, "descendant", "child", "adjacent", "siblings"
  combinator : String
  name : String?
  classes : Array[String]
  ids : Array[String]
  attributes : Array[AttributeTest]
  pseudo : Array[String]
}

///|
priv struct Rule {
  selector : Array[Compound]
  declarations : Array[(String, String)]
  specificity : (Int, Int, Int, Int)
}

///|
fn is_ident_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-' ||
  (c.to_int() >= 0xA0 && c.to_int() <= 0xFFFF)
}

///|
priv enum Token {
  Modifier(String)
  Ident(StringBuilder)
  Comb(String)
  Attr(AttributeTest)
}

///|
/// prawn-svg's `SelectorParser`: None for a selector it does not support.
fn parse_selector(text : String) -> Array[Compound]? {
  let tokens : Array[Token] = []
  let mut brackets = false
  // attribute parsing state: "" when outside an attribute
  let mut attr_state = ""
  let mut key = StringBuilder()
  let mut op = StringBuilder()
  let mut value = StringBuilder()
  let mut has_op = false
  let mut quote = false
  let push_attr = fn() {
    tokens.push(
      Attr({
        key: key.to_string(),
        op: if has_op {
          Some(op.to_string())
        } else {
          None
        },
        value: value.to_string(),
      }),
    )
  }
  for c in strip(text) {
    if brackets {
      match tokens.last() {
        Some(Ident(sb)) => sb.write_char(c)
        _ => return None
      }
      if c == ')' {
        brackets = false
      }
    } else if attr_state != "" {
      match attr_state {
        "pre_key" =>
          if is_ident_char(c) {
            key = StringBuilder()
            key.write_char(c)
            op = StringBuilder()
            value = StringBuilder()
            has_op = false
            attr_state = "key"
          } else if c != ' ' && c != '\t' {
            return None
          }
        "key" =>
          if is_ident_char(c) {
            key.write_char(c)
          } else if c == ']' {
            push_attr()
            attr_state = ""
          } else if "=*~^|$".contains_char(c) {
            op.write_char(c)
            has_op = true
            attr_state = "operator"
          } else if c == ' ' || c == '\t' {
            attr_state = "pre_operator"
          } else {
            return None
          }
        "pre_operator" =>
          if "=*~^|$".contains_char(c) {
            op.write_char(c)
            has_op = true
            attr_state = "operator"
          } else if c == ']' {
            // prawn-svg rejects this; a key alone must close at once
            return None
          } else if c != ' ' && c != '\t' {
            return None
          }
        "operator" =>
          if "=*~^|$".contains_char(c) {
            op.write_char(c)
          } else if c == ' ' || c == '\t' {
            attr_state = "pre_value"
          } else if c == '"' || c == '\'' {
            attr_state = c.to_string()
          } else {
            value.write_char(c)
            attr_state = "value"
          }
        "pre_value" =>
          if c == '"' || c == '\'' {
            attr_state = c.to_string()
          } else if c != ' ' && c != '\t' {
            value.write_char(c)
            attr_state = "value"
          }
        "value" =>
          if c == ']' {
            let v = value.to_string()
            value = StringBuilder()
            value.write_string(v.trim_end(chars=" \t\n\r").to_owned())
            push_attr()
            attr_state = ""
          } else {
            value.write_char(c)
          }
        "post_string" =>
          if c == ']' {
            push_attr()
            attr_state = ""
          } else if c != ' ' && c != '\t' {
            return None
          }
        q =>
          // inside a quoted value
          if c == '\\' && !quote {
            quote = true
          } else if q == c.to_string() && !quote {
            attr_state = "post_string"
          } else {
            quote = false
            value.write_char(c)
          }
      }
    } else if is_ident_char(c) {
      match tokens.last() {
        Some(Ident(sb)) => sb.write_char(c)
        last => {
          if !(last is Some(Modifier(_))) {
            tokens.push(Modifier("name"))
          }
          let sb = StringBuilder()
          sb.write_char(c)
          tokens.push(Ident(sb))
        }
      }
    } else {
      let pop_descendant = fn() {
        if tokens.last() is Some(Comb("descendant")) {
          ignore(tokens.pop())
        }
      }
      match c {
        '.' => tokens.push(Modifier("class"))
        '#' => tokens.push(Modifier("id"))
        ':' => tokens.push(Modifier("pseudo_class"))
        ' ' | '\t' =>
          if !(tokens.last() is Some(Comb(_))) {
            tokens.push(Comb("descendant"))
          }
        '>' => {
          pop_descendant()
          tokens.push(Comb("child"))
        }
        '+' => {
          pop_descendant()
          tokens.push(Comb("adjacent"))
        }
        '~' => {
          pop_descendant()
          tokens.push(Comb("siblings"))
        }
        '*' => {
          if !(tokens.is_empty() || tokens.last() is Some(Comb(_))) {
            return None
          }
          tokens.push(Modifier("name"))
          let sb = StringBuilder()
          sb.write_char('*')
          tokens.push(Ident(sb))
        }
        '(' => {
          let n = tokens.length()
          guard n >= 2 &&
            tokens[n - 1] is Ident(sb) &&
            tokens[n - 2] is Modifier("pseudo_class") else {
            return None
          }
          sb.write_char('(')
          brackets = true
        }
        '[' => attr_state = "pre_key"
        _ => return None
      }
    }
  }
  if brackets || attr_state != "" {
    return None
  }
  // group the tokens into compounds
  let result : Array[Compound] = [
    {
      combinator: "",
      name: None,
      classes: [],
      ids: [],
      attributes: [],
      pseudo: [],
    },
  ]
  let mut part : String? = None
  for token in tokens {
    let last = result.length() - 1
    match token {
      Modifier(kind) => part = Some(kind)
      Ident(sb) =>
        match part {
          None => return None
          Some("name") =>
            result[last] = {
              ..result[last],
              name: Some(result[last].name.unwrap_or("") + sb.to_string()),
            }
          Some("class") => result[last].classes.push(sb.to_string())
          Some("id") => result[last].ids.push(sb.to_string())
          Some(_) => result[last].pseudo.push(sb.to_string())
        }
      Attr(check) => {
        guard check.op is (None | Some("=" | "*=" | "~=" | "^=" | "|=" | "$=")) else {
          return None
        }
        result[last].attributes.push(check)
      }
      Comb(kind) => {
        result.push({
          combinator: kind,
          name: None,
          classes: [],
          ids: [],
          attributes: [],
          pseudo: [],
        })
        part = None
      }
    }
  }
  Some(result)
}

///|
fn specificity(selector : Array[Compound], order : Int) -> (Int, Int, Int, Int) {
  let mut a = 0
  let mut b = 0
  let mut c = 0
  for compound in selector {
    a += compound.ids.length()
    b += compound.classes.length() +
      compound.attributes.length() +
      compound.pseudo.length()
    if compound.name is Some(n) && n != "*" {
      c += 1
    }
  }
  (a, b, c, order)
}

///|
/// Remove `/* ... */` comments.
fn strip_css_comments(css : String) -> String {
  let sb = StringBuilder()
  let n = css.length()
  let mut i = 0
  while i < n {
    if css[i] == '/' && i + 1 < n && css[i + 1] == '*' {
      match find_from(css, "*/", i + 2) {
        Some(end) => i = end + 2
        None => i = n
      }
    } else {
      sb.write_char(css[i].unsafe_to_char())
      i += 1
    }
  }
  sb.to_string()
}

///|
/// The declarations of a block: `name: value` pairs split on `;`, names
/// in lower case and `!important` dropped (css_parser's parsing).
fn parse_declarations(block : String) -> Array[(String, String)] {
  let out = []
  for decl in block.split(";") {
    guard decl.find(":") is Some(colon) else { continue }
    let name = downcase(strip(decl[:colon]))
    let mut value = strip(decl[colon + 1:])
    let lower = downcase(value)
    match lower.rev_find("!important") {
      Some(i) => value = strip(value[:i])
      None => ()
    }
    if name != "" && value != "" {
      out.push((name, value))
    }
  }
  out
}

///|
/// The rule sets of a stylesheet, as (selector list, declarations);
/// `@media` blocks contribute their rules, other at-rules nothing.
fn parse_rule_sets(css : String, out : Array[(String, String)]) -> Unit {
  let css = strip_css_comments(css)
  let n = css.length()
  let mut i = 0
  while i < n {
    while i < n && (is_ws(css[i]) || css[i] == ';' || css[i] == '}') {
      i += 1
    }
    if i >= n {
      break
    }
    // the prelude up to `{` (or `;` for a statement at-rule)
    let start = i
    while i < n && css[i] != '{' && css[i] != ';' {
      i += 1
    }
    let prelude = strip(css.unsafe_substring(start~, end=i))
    if i >= n {
      break
    }
    if css[i] == ';' {
      i += 1
      continue
    }
    // the block, with nested braces
    let body_start = i + 1
    let mut depth = 1
    i += 1
    while i < n && depth > 0 {
      if css[i] == '{' {
        depth += 1
      } else if css[i] == '}' {
        depth -= 1
      }
      i += 1
    }
    let body_end = if depth == 0 { i - 1 } else { n }
    let body = css.unsafe_substring(start=body_start, end=body_end)
    if prelude.has_prefix("@") {
      if downcase(prelude).has_prefix("@media") {
        parse_rule_sets(body, out)
      }
    } else {
      out.push((prelude, body))
    }
  }
}

///|
let user_agent_stylesheet : String = "svg, symbol, image, marker, pattern, foreignObject { overflow: hidden }"

///|
/// Parse the user agent sheet and the `<style>` elements into rules sorted
/// by specificity and order.
fn load_rules(root : Element) -> Array[Rule] {
  let sets = []
  parse_rule_sets(user_agent_stylesheet, sets)
  for e in root.descendants() {
    if e.name == "style" {
      parse_rule_sets(e.text(), sets)
    }
  }
  let rules = []
  let mut order = 0
  for set in sets {
    let (selectors, body) = set
    let declarations = parse_declarations(body)
    for selector_text in selectors.split(",") {
      match parse_selector(selector_text.to_owned()) {
        Some(selector) => {
          rules.push({
            selector,
            declarations,
            specificity: specificity(selector, order),
          })
          order += 1
        }
        None => ()
      }
    }
  }
  rules.sort_by_key(rule => rule.specificity)
  rules
}

///|
fn attr_matches(e : Element, check : AttributeTest) -> Bool {
  guard e.attr(check.key) is Some(actual) else { return false }
  let v = check.value
  match check.op {
    None => true
    Some("=") => actual == v
    Some("^=") => actual.has_prefix(v)
    Some("$=") => actual.has_suffix(v)
    Some("*=") => actual.contains(v)
    Some("~=") => (" " + actual + " ").contains(" " + v + " ")
    Some("|=") => ("-" + actual + "-").contains("-" + v + "-")
    _ => false
  }
}

///|
/// Whether `e` passes a compound's tests other than position.
fn compound_matches(compound : Compound, e : Element) -> Bool {
  match compound.name {
    Some(name) if name != "*" && name != e.name => return false
    _ => ()
  }
  if !compound.classes.is_empty() {
    let padded = " " + e.attr("class").unwrap_or("") + " "
    for cls in compound.classes {
      if !padded.contains(" " + cls + " ") {
        return false
      }
    }
  }
  for id in compound.ids {
    if e.attr("id") != Some(id) {
      return false
    }
  }
  for check in compound.attributes {
    if !attr_matches(e, check) {
      return false
    }
  }
  true
}

///|
/// The positions (1-based, `-1` for last) a compound's pseudo-classes
/// require; a combinator of `adjacent` requires the first following
/// sibling.
fn compound_positions(compound : Compound) -> Array[Int] {
  let out = []
  let pseudo = compound.pseudo.copy()
  if compound.combinator == "adjacent" && !pseudo.contains("first-child") {
    pseudo.push("first-child")
  }
  let seen = []
  for pc in pseudo {
    if seen.contains(pc) {
      continue
    }
    seen.push(pc)
    if pc == "first-child" {
      out.push(1)
    } else if pc == "last-child" {
      out.push(-1)
    } else if pc.has_prefix("nth-child(") && pc.has_suffix(")") {
      let inner = pc.unsafe_substring(start=10, end=pc.length() - 1)
      if inner != "" && inner.iter().all(c => c >= '0' && c <= '9') {
        out.push(@string.parse_int(inner) catch { _ => 0 })
      }
    }
  }
  out
}

///|
fn at_positions(positions : Array[Int], index : Int, count : Int) -> Bool {
  for p in positions {
    if p == -1 {
      if index != count {
        return false
      }
    } else if p != index {
      return false
    }
  }
  true
}

///|
/// The elements a selector selects, in document order (`order` numbers
/// every element of the tree).
fn select(
  root : Element,
  all : Array[Element],
  order : Map[Int, Int],
  selector : Array[Compound],
) -> Array[Element] {
  // the context set, as marks by document order; before the first
  // compound it is the document node, above the root
  let mut current : Array[Element]? = None
  for compound in selector {
    let positions = compound_positions(compound)
    let next : Array[Element] = []
    let marked : Map[Int, Bool] = Map([])
    let add = fn(e : Element) {
      let k = e.uid
      if !marked.contains(k) {
        marked[k] = true
        next.push(e)
      }
    }
    // position among the parent's element children
    let child_position = fn(e : Element) -> Bool {
      if positions.is_empty() {
        return true
      }
      match e.parent() {
        Some(p) => {
          let siblings = p.elements()
          let mut index = 0
          for i, s in siblings {
            if physical_equal(s, e) {
              index = i + 1
            }
          }
          at_positions(positions, index, siblings.length())
        }
        None => at_positions(positions, 1, 1)
      }
    }
    match (current, compound.combinator) {
      (None, _) | (Some(_), "descendant") => {
        let context : Map[Int, Bool] = Map([])
        match current {
          Some(set) =>
            for e in set {
              context[e.uid] = true
            }
          None => ()
        }
        // walk the tree, tracking whether an ancestor is in the context
        let stack : Array[(Element, Bool)] = [(root, current is None)]
        while stack.pop() is Some((e, inside)) {
          if inside && compound_matches(compound, e) && child_position(e) {
            add(e)
          }
          let below = inside || context.contains(e.uid)
          let kids = e.elements()
          for j = kids.length() - 1; j >= 0; j = j - 1 {
            stack.push((kids[j], below))
          }
        }
      }
      (Some(set), "child") =>
        for c in set {
          for e in c.elements() {
            if compound_matches(compound, e) && child_position(e) {
              add(e)
            }
          }
        }
      (Some(set), _) =>
        // adjacent and general siblings: positions along the following
        // siblings of each context element
        for c in set {
          guard c.parent() is Some(p) else { continue }
          let siblings = p.elements()
          let mut after = -1
          for i, s in siblings {
            if physical_equal(s, c) {
              after = i
            }
          }
          if after < 0 {
            continue
          }
          let following = siblings[after + 1:]
          for i, e in following {
            if compound_matches(compound, e) &&
              at_positions(positions, i + 1, following.length()) {
              add(e)
            }
          }
        }
    }
    current = Some(next)
  }
  let result = current.unwrap_or([])
  result.sort_by_key(e => order.get(e.uid).unwrap_or(0))
  ignore(all)
  result
}

///|
/// The declarations each element gets from the stylesheets, keyed by
/// `key` (see `Document`).
fn element_styles(
  root : Element,
  all : Array[Element],
) -> Map[Int, Array[(String, String)]] {
  let styles : Map[Int, Array[(String, String)]] = Map([])
  let rules = load_rules(root)
  if rules.is_empty() {
    return styles
  }
  let order : Map[Int, Int] = Map([])
  for i, e in all {
    order[e.uid] = i
  }
  for rule in rules {
    for e in select(root, all, order, rule.selector) {
      match styles.get(e.uid) {
        Some(list) => list.append(rule.declarations)
        None => styles[e.uid] = rule.declarations.copy()
      }
    }
  }
  styles
}
