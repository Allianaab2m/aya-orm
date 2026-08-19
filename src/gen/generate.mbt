///|
pub(all) suberror GenError {
  /// The input file is not valid MoonBit.
  ParseFailed(name~ : String, diagnostics~ : Int)
} derive(Debug)

///|
/// Parse an entity source file and produce its generated companion.
///
/// String in, string out: file IO stays in the CLI so the whole pipeline is
/// testable without touching the filesystem.
pub fn generate(
  source : String,
  name? : String = "<input>",
) -> String raise Error {
  let (impls, reports) = @parser.parse_string(source, name~)
  if reports.length() > 0 {
    raise ParseFailed(name~, diagnostics=reports.length())
  }
  emit_file(collect_entities(impls))
}
