///|
pub(all) suberror GenError {
  /// The input file is not valid MoonBit.
  ParseFailed(name~ : String, diagnostics~ : Int)
} derive(Debug)

///|
/// Parse a source file and lower every `#cairn.table` in it.
///
/// The shared front half of both generators: the column-handle emitter and the
/// DDL emitter must see the same entities, or the code and the schema drift.
pub fn entities_of(
  source : String,
  name? : String = "<input>",
) -> Array[EntitySpec] raise Error {
  let (impls, reports) = @parser.parse_string(source, name~)
  if reports.length() > 0 {
    raise ParseFailed(name~, diagnostics=reports.length())
  }
  collect_entities(impls)
}

///|
/// Parse an entity source file and produce its generated companion.
///
/// String in, string out: file IO stays in the CLI so the whole pipeline is
/// testable without touching the filesystem.
pub fn generate(
  source : String,
  name? : String = "<input>",
) -> String raise Error {
  emit_file(entities_of(source, name~))
}
