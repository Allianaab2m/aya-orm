///|
pub(all) suberror KitError {
  /// `cairn.json` could not be read.
  BadConfig(reason~ : String)
  /// `meta/_journal.json` could not be read.
  BadJournal(reason~ : String)
  /// The migrations directory and the config disagree about the dialect.
  DialectMismatch(journal~ : String, config~ : String)
} derive(Debug)

///|
/// Where the project keeps its schema and its migrations.
///
/// A file rather than flags, for the same reason drizzle has one: every
/// command needs the same three answers, and a repository should not depend on
/// each developer typing them the same way.
pub(all) struct Config {
  dialect : @sql.Dialect
  /// Files or directories to scan for `#cairn.table` declarations.
  schema : Array[String]
  /// Directory holding the migrations and their snapshots.
  out : String
} derive(Debug, Eq)

///|
/// The name looked for when `--config` is not given.
pub const CONFIG_FILE = "cairn.json"

///|
/// What a project gets without a config file.
pub fn Config::new() -> Config {
  { dialect: Sqlite, schema: ["src"], out: "migrations" }
}

///|
/// Read a config file.
///
/// Every key is optional: a project that only overrides `schema` should not
/// have to restate the defaults.
pub fn Config::from_json_string(text : String) -> Config raise KitError {
  let json = @json.parse(text) catch {
    e => raise BadConfig(reason="not valid JSON: \{e}")
  }
  guard json is Object(obj) else {
    raise BadConfig(reason="expected a JSON object")
  }
  let base = Config::new()
  let dialect = match obj.get("dialect") {
    None => base.dialect
    Some(String(s)) =>
      @ddl.dialect_of_name(s) catch {
        e => raise BadConfig(reason=e.to_string())
      }
    Some(_) => raise BadConfig(reason="`dialect` must be a string")
  }
  let schema = match obj.get("schema") {
    None => base.schema
    Some(String(s)) => [s]
    Some(Array(items)) => {
      let paths = []
      for item in items {
        guard item is String(s) else {
          raise BadConfig(reason="`schema` entries must be strings")
        }
        paths.push(s)
      }
      paths
    }
    Some(_) => raise BadConfig(reason="`schema` must be a string or an array")
  }
  let out = match obj.get("out") {
    None => base.out
    Some(String(s)) => s
    Some(_) => raise BadConfig(reason="`out` must be a string")
  }
  { dialect, schema, out }
}

///|
/// Render a config file, for `cairn-kit init`.
pub fn Config::to_json_string(self : Config) -> String {
  let schema = self.schema.map(s => "\n    \{quote(s)}").join(",")
  let list = if self.schema.is_empty() { "[]" } else { "[\{schema}\n  ]" }
  "{\n" +
  "  \"dialect\": \{quote(@ddl.dialect_name(self.dialect))},\n" +
  "  \"schema\": \{list},\n" +
  "  \"out\": \{quote(self.out)}\n" +
  "}\n"
}

///|
/// Minimal JSON string quoting, for the two files this package writes.
fn quote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("\"")
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      _ => buf.write_char(c)
    }
  }
  buf.write_string("\"")
  buf.to_string()
}

///|
pub impl Show for KitError with fn output(self, logger) {
  logger.write_string(
    match self {
      BadConfig(reason~) => "\{CONFIG_FILE}: \{reason}"
      BadJournal(reason~) => "migration journal: \{reason}"
      DialectMismatch(journal~, config~) =>
        "the migrations directory was written for `\{journal}` but the config says `\{config}`"
    },
  )
}
