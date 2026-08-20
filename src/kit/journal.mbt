///|
/// One migration that has been generated, in the order it must run.
pub(all) struct JournalEntry {
  idx : Int
  /// File stem shared by the migration and nothing else, e.g. `0001_add_plan`.
  tag : String
  /// Milliseconds since the epoch, as reported by the runtime that generated
  /// it. Ordering comes from `idx`; this is here for humans reading the file.
  when_ : Int64
  /// Whether the `.sql` file is split with statement breakpoints.
  breakpoints : Bool
} derive(Debug, Eq)

///|
/// The index of the migrations directory.
///
/// The directory listing cannot be the index: file names sort lexically, tell
/// you nothing about which dialect they were written for, and say nothing when
/// one is deleted by hand.
pub(all) struct Journal {
  version : String
  dialect : @sql.Dialect
  entries : Array[JournalEntry]
} derive(Debug, Eq)

///|
pub const JOURNAL_VERSION = "1"

///|
pub fn Journal::new(dialect : @sql.Dialect) -> Journal {
  { version: JOURNAL_VERSION, dialect, entries: [] }
}

///|
/// The last migration generated, if any.
pub fn Journal::last(self : Journal) -> JournalEntry? {
  if self.entries.is_empty() {
    None
  } else {
    Some(self.entries[self.entries.length() - 1])
  }
}

///|
/// The index the next migration will take.
pub fn Journal::next_index(self : Journal) -> Int {
  match self.last() {
    None => 0
    Some(e) => e.idx + 1
  }
}

///|
pub fn Journal::to_json_string(self : Journal) -> String {
  let buf = StringBuilder::new()
  buf.write_string("{\n")
  buf.write_string("  \"version\": \{quote(self.version)},\n")
  buf.write_string(
    "  \"dialect\": \{quote(@ddl.dialect_name(self.dialect))},\n",
  )
  buf.write_string("  \"entries\": [")
  for i, e in self.entries {
    buf.write_string(if i == 0 { "\n" } else { ",\n" })
    buf.write_string(
      "    { \"idx\": \{e.idx}, \"tag\": \{quote(e.tag)}, \"when\": \{e.when_}, \"breakpoints\": \{e.breakpoints} }",
    )
  }
  buf.write_string(
    if self.entries.is_empty() {
      "]\n}\n"
    } else {
      "\n  ]\n}\n"
    },
  )
  buf.to_string()
}

///|
pub fn Journal::from_json_string(text : String) -> Journal raise KitError {
  let json = @json.parse(text) catch {
    e => raise BadJournal(reason="not valid JSON: \{e}")
  }
  guard json is Object(obj) else {
    raise BadJournal(reason="expected a JSON object")
  }
  let version = match obj.get("version") {
    Some(String(s)) => s
    _ => raise BadJournal(reason="missing `version`")
  }
  guard version == JOURNAL_VERSION else {
    raise BadJournal(
      reason="journal format version \{version}, this aya writes \{JOURNAL_VERSION}",
    )
  }
  let dialect = match obj.get("dialect") {
    Some(String(s)) =>
      @ddl.dialect_of_name(s) catch {
        e => raise BadJournal(reason=e.to_string())
      }
    _ => raise BadJournal(reason="missing `dialect`")
  }
  let entries = []
  guard obj.get("entries") is Some(Array(items)) else {
    raise BadJournal(reason="missing `entries`")
  }
  for item in items {
    guard item is Object(e) else {
      raise BadJournal(reason="every entry must be an object")
    }
    let idx = match e.get("idx") {
      Some(Number(n, ..)) => n.to_int()
      _ => raise BadJournal(reason="an entry is missing `idx`")
    }
    let tag = match e.get("tag") {
      Some(String(s)) => s
      _ => raise BadJournal(reason="entry \{idx} is missing `tag`")
    }
    entries.push({
      idx,
      tag,
      when_: match e.get("when") {
        Some(Number(n, ..)) => n.to_int64()
        _ => 0
      },
      breakpoints: !(e.get("breakpoints") is Some(False)),
    })
  }
  entries.sort_by_key(e => e.idx)
  { version, dialect, entries }
}
