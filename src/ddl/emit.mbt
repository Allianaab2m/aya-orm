///|
/// Render the statements that take `before` to `after`.
///
/// Dispatching on the *target* snapshot's dialect, not on an argument: a
/// snapshot records which dialect it was written for, so a migration cannot be
/// generated against a snapshot of another database by accident.
pub fn statements(
  before : Snapshot,
  after : Snapshot,
) -> Array[String] raise DdlError {
  guard before.dialect == after.dialect else {
    raise UnsupportedDialect(
      dialect=dialect_name(after.dialect),
      reason="the previous snapshot is for \{dialect_name(before.dialect)}",
    )
  }
  match after.dialect {
    Sqlite => sqlite_statements(before, after)
    Postgres =>
      raise UnsupportedDialect(
        dialect="postgres",
        reason="the type mapping is in place but the DDL emitter is not written yet",
      )
  }
}

///|
/// Quote an identifier, doubling any embedded quote.
///
/// Both dialects cairn targets accept the SQL standard's double quotes, which
/// is also what `sql/emit.mbt` writes for column references.
pub fn ident(name : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("\"")
  for c in name {
    if c == '"' {
      buf.write_string("\"\"")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_string("\"")
  buf.to_string()
}

///|
/// What separates two statements inside a generated migration file.
///
/// A marker rather than a bare `;`: a default expression or a trigger body can
/// contain a semicolon, so a runner that splits on `;` eventually splits in
/// the wrong place.
pub const BREAKPOINT = "--> statement-breakpoint"

///|
/// Render statements as the body of a `.sql` migration file.
pub fn migration_sql(statements : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i, s in statements {
    if i > 0 {
      buf.write_string("\{BREAKPOINT}\n")
    }
    buf.write_string(s)
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// Split a migration file back into the statements that made it.
///
/// The mirror of `migration_sql`, so a runner does not have to reimplement the
/// split, and so the round trip can be tested.
pub fn split_migration(text : String) -> Array[String] {
  let out = []
  let current = StringBuilder::new()
  let mut empty = true
  for line in text.split("\n") {
    if line.trim() == BREAKPOINT {
      if !empty {
        out.push(current.to_string().trim().to_owned())
      }
      current.reset()
      empty = true
    } else {
      current.write_stringview(line)
      current.write_string("\n")
      if !line.trim().is_empty() {
        empty = false
      }
    }
  }
  if !empty {
    out.push(current.to_string().trim().to_owned())
  }
  out
}
