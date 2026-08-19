///|
/// An INSERT statement over one table.
pub struct Insert {
  table_name : String
  columns : Array[String]
  rows : Array[Array[SqlValue]]
}

///|
/// Insert one row, writing every column the table's binding covers.
pub fn[C, R] insert(t : Table[C, R], row : R) -> Insert {
  insert_many(t, [row])
}

///|
/// Insert several rows in a single statement.
///
/// Emitting one statement rather than N keeps the parameters in a single
/// ordered list, which is what a driver needs to bind them.
pub fn[C, R] insert_many(t : Table[C, R], rows : Array[R]) -> Insert {
  {
    table_name: t.table_name,
    columns: t.write.columns,
    rows: rows.map(r => (t.write.write)(r)),
  }
}

///|
/// Insert every column except the named ones.
///
/// Typically used to let the database assign an auto-increment primary key.
pub fn[C, R] insert_except(
  t : Table[C, R],
  row : R,
  omit~ : Array[String],
) -> Insert {
  let binding = t.write.without(omit)
  {
    table_name: t.table_name,
    columns: binding.columns,
    rows: [(binding.write)(row)],
  }
}

///|
pub(all) suberror StatementError {
  /// An INSERT was built with no rows, which has no valid SQL form.
  EmptyInsert(table~ : String)
  /// A row supplied a different number of values than the binding has columns.
  ArityMismatch(table~ : String, expected~ : Int, got~ : Int)
  /// An UPDATE was built without any assignment.
  EmptyUpdate(table~ : String)
  /// Two tables in one query claim the same alias, so column references in the
  /// generated SQL would be ambiguous. Self-joins need distinct aliases, which
  /// cairn cannot yet assign (see `Table` docs).
  DuplicateAlias(tbl~ : String)
} derive(Debug)

///|
pub fn Insert::to_sql(
  self : Insert,
  dialect? : Dialect = Dialect::Sqlite,
) -> (String, Array[SqlValue]) raise StatementError {
  guard self.rows.length() > 0 else { raise EmptyInsert(table=self.table_name) }
  let em = Emitter::new(dialect)
  let buf = StringBuilder::new()
  let cols = join(self.columns.map(c => "\"\{c}\""), ", ")
  buf.write_string("INSERT INTO \"\{self.table_name}\" (\{cols})")
  let tuples = []
  for row in self.rows {
    guard row.length() == self.columns.length() else {
      raise ArityMismatch(
        table=self.table_name,
        expected=self.columns.length(),
        got=row.length(),
      )
    }
    tuples.push("(" + join(row.map(v => em.param(v)), ", ") + ")")
  }
  buf.write_string("\n VALUES " + join(tuples, ", "))
  (buf.to_string(), em.params)
}
