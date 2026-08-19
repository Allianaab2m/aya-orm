///|
/// A `#cairn.*` attribute recovered from source text.
///
/// `moonbitlang/parser` hands us attributes with `raw` filled in but `parsed`
/// left as `None` for user-defined namespaces, so we read `raw` ourselves.
/// `Attribute::name()` drops the namespace (`#cairn.id` and `#morm.id` both
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
/// Parse one raw attribute such as `#cairn.entity(table="users", alias="u")`.
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
const NAMESPACE = "cairn"

///|
/// Parse `k="v", k2="v2"` into a map.
///
/// Values must be quoted; MoonBit accepts arbitrary token soup inside an
/// attribute, but everything cairn needs is a string literal, so anything else
/// is rejected loudly rather than silently dropped.
fn parse_args(
  inner : StringView,
  raw : String,
) -> Map[String, String] raise AttrError {
  let args = Map([])
  for part in inner.split(",") {
    let piece = part.trim()
    if piece.is_empty() {
      continue
    }
    let eq = match piece.find("=") {
      Some(i) => i
      None =>
        raise Malformed(raw~, reason="expected `key=\"value\"` in `\{piece}`")
    }
    let key = piece[:eq].trim().to_owned()
    let value = piece[eq + 1:].trim()
    guard value.length() >= 2 &&
      value.has_prefix("\"") &&
      value.has_suffix("\"") else {
      raise Malformed(raw~, reason="value of `\{key}` must be a quoted string")
    }
    args[key] = value[1:value.length() - 1].to_owned()
  }
  args
}

///|
/// Look up an optional string argument.
pub fn Attr::arg(self : Attr, key : String) -> String? {
  self.args.get(key)
}
