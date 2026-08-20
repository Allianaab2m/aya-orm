///|
/// A `#aya.*` attribute recovered from source text.
///
/// `moonbitlang/parser` hands us attributes with `raw` filled in but `parsed`
/// left as `None` for user-defined namespaces, so we read `raw` ourselves.
/// `Attribute::name()` drops the namespace (`#aya.id` and `#morm.id` both
/// report `"id"`), which is not good enough to tell our attributes apart.
pub struct Attr {
  name : String
  args : Map[String, String]
} derive(Debug, Eq)

///|
pub(all) suberror AttrError {
  /// The attribute payload could not be read.
  Malformed(raw~ : String, reason~ : String)
} derive(Debug)

///|
/// Parse one raw attribute such as `#aya.entity(table="users", alias="u")`.
///
/// Returns `None` when the attribute belongs to another namespace, so callers
/// can ignore `#deprecated`, `#morm.entity`, and friends without special cases.
pub fn parse_attr(raw : String) -> Attr? raise AttrError {
  let text = raw.trim()
  guard text.has_prefix("#" + NAMESPACE + ".") else { None }
  let body = text[NAMESPACE.length() + 2:]
  match body.find("(") {
    None => Some({ name: body.trim().to_owned(), args: Map([]) })
    Some(open) => {
      guard body.has_suffix(")") else {
        raise Malformed(raw~, reason="unterminated argument list")
      }
      Some({
        name: body[:open].trim().to_owned(),
        args: parse_args(body[open + 1:body.length() - 1], raw),
      })
    }
  }
}

///|
/// The attribute namespace this generator claims.
const NAMESPACE = "aya"

///|
/// Parse `k="v", k2="v2"` into a map.
///
/// Scanned character by character rather than split on commas, because the
/// values that matter most here are SQL fragments: `default="coalesce(a, b)"`
/// has a comma inside the quotes, and splitting on it would lose half the
/// expression without saying so.
fn parse_args(
  inner : StringView,
  raw : String,
) -> Map[String, String] raise AttrError {
  let args = Map([])
  let cs = []
  for c in inner {
    cs.push(c)
  }
  let n = cs.length()
  let mut i = 0
  fn skip_spaces() {
    while i < n && cs[i].is_whitespace() {
      i = i + 1
    }
  }

  while i < n {
    skip_spaces()
    if i >= n {
      break
    }
    let key_start = i
    while i < n && cs[i] != '=' && !cs[i].is_whitespace() {
      i = i + 1
    }
    let key = take(cs, key_start, i)
    if key.is_empty() {
      raise Malformed(raw~, reason="expected an argument name")
    }
    skip_spaces()
    guard i < n && cs[i] == '=' else {
      raise Malformed(raw~, reason="expected `=` after `\{key}`")
    }
    i = i + 1
    skip_spaces()
    guard i < n && cs[i] == '"' else {
      raise Malformed(raw~, reason="value of `\{key}` must be a quoted string")
    }
    i = i + 1
    let value = StringBuilder::new()
    let mut closed = false
    while i < n {
      let c = cs[i]
      if c == '"' {
        closed = true
        i = i + 1
        break
      }
      // A backslash escape is passed through with its backslash removed, so
      // `default="\"n/a\""` reaches the emitter as `"n/a"`.
      if c == '\\' && i + 1 < n {
        value.write_char(cs[i + 1])
        i = i + 2
      } else {
        value.write_char(c)
        i = i + 1
      }
    }
    guard closed else {
      raise Malformed(raw~, reason="unterminated value for `\{key}`")
    }
    args[key] = value.to_string()
    skip_spaces()
    if i < n {
      guard cs[i] == ',' else {
        raise Malformed(raw~, reason="expected `,` after `\{key}`")
      }
      i = i + 1
    }
  }
  args
}

///|
/// The characters in `[start, end)` as a string.
fn take(cs : Array[Char], start : Int, end : Int) -> String {
  let buf = StringBuilder::new()
  for i in start..<end {
    buf.write_char(cs[i])
  }
  buf.to_string()
}

///|
/// Look up an optional string argument.
pub fn Attr::arg(self : Attr, key : String) -> String? {
  self.args.get(key)
}
