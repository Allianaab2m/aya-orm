///|
/// A migration, as the three files it becomes.
///
/// Produced without touching the filesystem so that the interesting part —
/// what SQL a schema edit turns into — is testable, and so a failure part-way
/// through cannot leave a `.sql` on disk with no snapshot beside it.
pub struct Migration {
  idx : Int
  /// File stem, e.g. `0001_add_column_accounts_plan`.
  tag : String
  /// Contents of `<out>/<tag>.sql`.
  sql : String
  /// Contents of `<out>/meta/<idx>_snapshot.json`.
  snapshot : String
} derive(Debug, Eq)

///|
/// What `generate` would do.
pub struct Plan {
  changes : Array[@ddl.Change]
  /// `None` when the schema already matches the last snapshot.
  migration : Migration?
  /// The journal as it will be after the migration is written.
  journal : Journal
} derive(Debug, Eq)

///|
/// Work out the next migration from the two snapshots around it.
///
/// `name` overrides the generated slug; without one the migration is named
/// after its first change, so the migrations directory reads as a changelog.
pub fn plan(
  journal~ : Journal,
  previous~ : @ddl.Snapshot,
  next~ : @ddl.Snapshot,
  now~ : Int64,
  name? : String,
) -> Plan raise Error {
  let changes = @ddl.diff(previous, next)
  if changes.is_empty() {
    return { changes, migration: None, journal }
  }
  let idx = journal.next_index()
  let tag = "\{pad_index(idx)}_\{name.unwrap_or(@ddl.auto_name(changes))}"
  let sql = @ddl.migration_sql(@ddl.statements(previous, next))
  let entries = journal.entries.copy()
  entries.push({ idx, tag, when_: now, breakpoints: true })
  {
    changes,
    migration: Some({ idx, tag, sql, snapshot: next.to_json_string() }),
    journal: { ..journal, entries, },
  }
}

///|
/// Parse every schema source and lower them all into one snapshot.
///
/// Sources are `(name, contents)` pairs; the name only ever shows up in a
/// parse error, so the caller decides whether that is a path or something
/// else.
pub fn snapshot_of_sources(
  sources : Array[(String, String)],
  dialect~ : @aya.Dialect,
) -> @ddl.Snapshot raise Error {
  let specs = []
  for src in sources {
    let (name, text) = src
    for spec in @gen.entities_of(text, name~) {
      specs.push(spec)
    }
  }
  @ddl.snapshot_of(specs, dialect~)
}

///|
/// A four-digit migration index: `12` -> `0012`.
///
/// Fixed width so the directory sorts the way the migrations run, which is the
/// order anyone reading it will assume anyway.
pub fn pad_index(idx : Int) -> String {
  let s = idx.to_string()
  if s.length() >= 4 {
    s
  } else {
    "0".repeat(4 - s.length()) + s
  }
}

///|
pub fn Config::meta_dir(self : Config) -> String {
  self.out + "/meta"
}

///|
pub fn Config::journal_path(self : Config) -> String {
  self.meta_dir() + "/_journal.json"
}

///|
pub fn Config::migration_path(self : Config, tag : String) -> String {
  self.out + "/" + tag + ".sql"
}

///|
pub fn Config::snapshot_path(self : Config, idx : Int) -> String {
  self.meta_dir() + "/" + pad_index(idx) + "_snapshot.json"
}

///|
/// A short report of what a plan would change, one line per change.
pub fn describe(changes : Array[@ddl.Change]) -> String {
  if changes.is_empty() {
    "no schema changes"
  } else {
    changes.map(c => "  " + c.summary()).join("\n")
  }
}
