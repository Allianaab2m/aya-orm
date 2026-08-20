///|
/// SQLite DDL.
///
/// SQLite's `ALTER TABLE` can add and drop plain columns and nothing else: a
/// type change, a new constraint, or dropping an indexed column all mean
/// rebuilding the table. That is the shape of this emitter — decide per table
/// whether a rebuild is needed, then either write the small ALTERs or the
/// twelve-step dance.
fn sqlite_statements(
  before : Snapshot,
  after : Snapshot,
) -> Array[String] raise DdlError {
  let changes = diff(before, after)
  let out : Array[String] = []
  let rebuilt : Array[String] = []

  // Which surviving tables have to be rebuilt. Decided up front so the index
  // statements around them know to stay out of the way.
  for t in after.tables {
    guard before.table(t.name) is Some(old) else { continue }
    let cs = column_changes(changes, t.name)
    check_column_changes(t.name, cs)
    if cs.length() > 0 && needs_rebuild(old, cs) {
      rebuilt.push(t.name)
    }
  }

  // 1. Index drops. A rebuilt table loses its indexes with the table itself.
  for c in changes {
    if c is DropIndex(table~, index~) && !rebuilt.contains(table) {
      out.push("DROP INDEX \{ident(index)};")
    }
  }

  // 2. New tables, with their indexes, before anything can reference them.
  let created : Array[TableDef] = []
  for c in changes {
    if c is CreateTable(t) {
      created.push(t)
    }
  }
  for t in creation_order(created) {
    out.push(create_table_sql(t, name=t.name))
    for idx in t.indexes {
      out.push(create_index_sql(t.name, idx))
    }
  }

  // 3. Column changes on surviving tables.
  for t in after.tables {
    guard before.table(t.name) is Some(old) else { continue }
    let cs = column_changes(changes, t.name)
    guard cs.length() > 0 else { continue }
    if rebuilt.contains(t.name) {
      for s in rebuild_table_sql(old, t) {
        out.push(s)
      }
    } else {
      for c in cs {
        match c {
          AddColumn(table~, column~) =>
            out.push("ALTER TABLE \{ident(table)} ADD \{column_sql(column)};")
          DropColumn(table~, column~) =>
            out.push(
              "ALTER TABLE \{ident(table)} DROP COLUMN \{ident(column)};",
            )
          _ => ()
        }
      }
    }
  }

  // 4. Tables that went away.
  for c in changes {
    if c is DropTable(name) {
      out.push("DROP TABLE \{ident(name)};")
    }
  }

  // 5. Index creations, plus everything a rebuilt table lost.
  for c in changes {
    if c is CreateIndex(table~, index~) && !rebuilt.contains(table) {
      out.push(create_index_sql(table, index))
    }
  }
  for t in after.tables {
    if rebuilt.contains(t.name) {
      for idx in t.indexes {
        out.push(create_index_sql(t.name, idx))
      }
    }
  }
  out
}

///|
/// The per-column changes recorded for one table.
fn column_changes(changes : Array[Change], table : String) -> Array[Change] {
  changes.filter(c => {
    match c {
      AddColumn(table=t, ..)
      | DropColumn(table=t, ..)
      | AlterColumn(table=t, ..) => t == table
      _ => false
    }
  })
}

///|
/// Reject changes no SQL can express against a table that already has rows.
///
/// Adding a `NOT NULL` column with no default is the common one: there is no
/// value to put in the existing rows, so neither `ALTER TABLE` nor a rebuild
/// can do it. Saying so here beats emitting SQL that fails at 3am.
fn check_column_changes(
  table : String,
  cs : Array[Change],
) -> Unit raise DdlError {
  for c in cs {
    let col = match c {
      AddColumn(column~, ..) => column
      AlterColumn(after~, before~, ..) =>
        if before.not_null || !after.not_null {
          continue
        } else {
          after
        }
      _ => continue
    }
    if col.not_null && col.default_sql is None {
      raise UnsafeChange(
        table~,
        reason="column `\{col.name}` is NOT NULL with no default, so existing rows have no value to take; add `#cairn.column(default=\"...\")` or make the field optional",
      )
    }
  }
}

///|
/// Whether a table's changes exceed what `ALTER TABLE` can do in SQLite.
fn needs_rebuild(old : TableDef, cs : Array[Change]) -> Bool {
  for c in cs {
    match c {
      AlterColumn(..) => return true
      // `ADD COLUMN` refuses PRIMARY KEY and UNIQUE outright.
      AddColumn(column~, ..) =>
        if column.primary_key || column.unique {
          return true
        }
      // `DROP COLUMN` refuses a column that is part of a key or an index.
      DropColumn(column~, ..) =>
        if old.column(column) is Some(prev) {
          if prev.primary_key || prev.unique {
            return true
          }
          for idx in old.indexes {
            if idx.columns.contains(column) {
              return true
            }
          }
        }
      _ => ()
    }
  }
  false
}

///|
/// Replace a table with one of the new shape, carrying the rows across.
///
/// The columns copied are the ones both shapes share: a dropped column has
/// nowhere to go, and a new one has nothing to come from — which is why
/// `check_column_changes` insists a new NOT NULL column has a default.
///
/// A column that became NOT NULL is copied through `coalesce`. Its default
/// covers rows inserted from now on, but the rows already stored can hold the
/// NULL the column used to allow, and a plain copy would fail against the new
/// constraint at exactly the moment the migration runs.
fn rebuild_table_sql(old : TableDef, new_table : TableDef) -> Array[String] {
  let tmp = "__new_" + new_table.name
  let names = []
  let values = []
  for c in new_table.columns {
    guard old.column(c.name) is Some(prev) else { continue }
    names.push(ident(c.name))
    if c.not_null && !prev.not_null && c.default_sql is Some(d) {
      values.push("coalesce(\{ident(c.name)}, \{d})")
    } else {
      values.push(ident(c.name))
    }
  }
  let out = ["PRAGMA foreign_keys=OFF;", create_table_sql(new_table, name=tmp)]
  if names.length() > 0 {
    out.push(
      "INSERT INTO \{ident(tmp)} (\{names.join(", ")})\nSELECT \{values.join(", ")} FROM \{ident(old.name)};",
    )
  }
  out.push("DROP TABLE \{ident(old.name)};")
  out.push("ALTER TABLE \{ident(tmp)} RENAME TO \{ident(new_table.name)};")
  out.push("PRAGMA foreign_keys=ON;")
  out
}

///|
/// `CREATE TABLE "t" ( ... );`
///
/// `name` is separate from `table.name` so a rebuild can create the same shape
/// under a temporary name.
fn create_table_sql(table : TableDef, name~ : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("CREATE TABLE \{ident(name)} (\n")
  for i, c in table.columns {
    buf.write_string("  ")
    buf.write_string(column_sql(c))
    buf.write_string(if i == table.columns.length() - 1 { "\n" } else { ",\n" })
  }
  buf.write_string(");")
  buf.to_string()
}

///|
/// One column's definition, as it appears inside `CREATE TABLE`.
fn column_sql(c : ColumnDef) -> String {
  let buf = StringBuilder::new()
  buf.write_string("\{ident(c.name)} \{c.ty}")
  if c.primary_key {
    buf.write_string(" PRIMARY KEY")
    if c.autoincrement {
      buf.write_string(" AUTOINCREMENT")
    }
  }
  if c.not_null {
    buf.write_string(" NOT NULL")
  }
  if c.unique && !c.primary_key {
    buf.write_string(" UNIQUE")
  }
  if c.default_sql is Some(d) {
    buf.write_string(" DEFAULT \{d}")
  }
  if c.references is Some(r) {
    buf.write_string(" REFERENCES \{ident(r.table)}(\{ident(r.column)})")
    if r.on_delete is Some(a) {
      buf.write_string(" ON DELETE \{a}")
    }
    if r.on_update is Some(a) {
      buf.write_string(" ON UPDATE \{a}")
    }
  }
  buf.to_string()
}

///|
fn create_index_sql(table : String, idx : IndexDef) -> String {
  let unique = if idx.unique { "UNIQUE " } else { "" }
  let cols = idx.columns.map(ident).join(", ")
  "CREATE \{unique}INDEX \{ident(idx.name)} ON \{ident(table)} (\{cols});"
}
