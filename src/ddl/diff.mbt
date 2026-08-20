///|
/// One step from the previous snapshot to the next one.
///
/// A rename is not in this list on purpose: nothing in the source says whether
/// a vanished column and a new one are the same column, and guessing wrong
/// silently deletes data. A rename shows up as a drop and an add, which is at
/// least visible in the generated SQL before it runs.
pub(all) enum Change {
  CreateTable(TableDef)
  DropTable(String)
  AddColumn(table~ : String, column~ : ColumnDef)
  DropColumn(table~ : String, column~ : String)
  AlterColumn(table~ : String, before~ : ColumnDef, after~ : ColumnDef)
  CreateIndex(table~ : String, index~ : IndexDef)
  DropIndex(table~ : String, index~ : String)
} derive(Debug, Eq)

///|
/// Compare two snapshots, in the order the statements should run.
///
/// Tables are created before columns move, so a new foreign key can point at a
/// table this same migration introduces.
pub fn diff(before : Snapshot, after : Snapshot) -> Array[Change] {
  let changes : Array[Change] = []
  // Index drops go first: on some engines a column cannot be dropped or
  // retyped while an index still covers it.
  for t in after.tables {
    if before.table(t.name) is Some(old) {
      for idx in old.indexes {
        if t.index(idx.name) != Some(idx) {
          changes.push(DropIndex(table=t.name, index=idx.name))
        }
      }
    }
  }
  for t in after.tables {
    if before.table(t.name) is None {
      changes.push(CreateTable(t))
    }
  }
  for t in before.tables {
    if after.table(t.name) is None {
      changes.push(DropTable(t.name))
    }
  }
  for t in after.tables {
    guard before.table(t.name) is Some(old) else { continue }
    for c in t.columns {
      match old.column(c.name) {
        None => changes.push(AddColumn(table=t.name, column=c))
        Some(prev) =>
          if prev != c {
            changes.push(AlterColumn(table=t.name, before=prev, after=c))
          }
      }
    }
    for c in old.columns {
      if t.column(c.name) is None {
        changes.push(DropColumn(table=t.name, column=c.name))
      }
    }
  }
  for t in after.tables {
    guard before.table(t.name) is Some(old) else { continue }
    for idx in t.indexes {
      if old.index(idx.name) != Some(idx) {
        changes.push(CreateIndex(table=t.name, index=idx))
      }
    }
  }
  changes
}

///|
/// A one-line description of a change, for `status` output and for naming a
/// migration after what it does.
pub fn Change::summary(self : Change) -> String {
  match self {
    CreateTable(t) => "create table \{t.name}"
    DropTable(name) => "drop table \{name}"
    AddColumn(table~, column~) => "add column \{table}.\{column.name}"
    DropColumn(table~, column~) => "drop column \{table}.\{column}"
    AlterColumn(table~, before=_, after~) =>
      "alter column \{table}.\{after.name}"
    CreateIndex(table=_, index~) => "create index \{index.name}"
    DropIndex(table=_, index~) => "drop index \{index}"
  }
}

///|
/// A file-name slug derived from what the migration actually does.
///
/// drizzle-kit names migrations after a random word pair; naming them after
/// the change means `git log` on the migrations directory reads as a schema
/// changelog. Falls back to `migration` when there is nothing to say.
pub fn auto_name(changes : Array[Change]) -> String {
  guard changes.length() > 0 else { return "migration" }
  let head = slug(changes[0].summary())
  if changes.length() == 1 {
    head
  } else {
    "\{head}_and_\{changes.length() - 1}_more"
  }
}

///|
/// Lower-case, underscore-separated, safe in a file name.
fn slug(s : String) -> String {
  let buf = StringBuilder::new()
  let mut written = false
  let mut pending_sep = false
  for c in s {
    if c.is_ascii_alphabetic() || c.is_ascii_digit() {
      if pending_sep && written {
        buf.write_char('_')
      }
      pending_sep = false
      written = true
      buf.write_char(c.to_ascii_lowercase())
    } else {
      pending_sep = true
    }
  }
  buf.to_string()
}

///|
/// Order tables so that a table comes after everything it references.
///
/// SQLite would not mind — it resolves foreign keys lazily — but a migration
/// file is also something a person reads, and "referenced first" is the order
/// the schema is easiest to follow in. It is also the order the stricter
/// dialects will need when their emitter arrives.
///
/// A reference cycle is left in name order rather than reported: two tables
/// pointing at each other is a legal schema, and this function's job is
/// presentation, not validation.
pub fn creation_order(tables : Array[TableDef]) -> Array[TableDef] {
  let out : Array[TableDef] = []
  let visiting : Array[String] = []
  fn visit(t : TableDef) -> Unit {
    if out.search_by(o => o.name == t.name) is Some(_) ||
      visiting.contains(t.name) {
      return
    }
    visiting.push(t.name)
    for c in t.columns {
      if c.references is Some(r) && r.table != t.name {
        if tables.search_by(o => o.name == r.table) is Some(i) {
          visit(tables[i])
        }
      }
    }
    let _ = visiting.pop()
    out.push(t)
  }

  for t in tables {
    visit(t)
  }
  out
}
