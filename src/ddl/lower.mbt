///|
/// Turn the entities found in the schema sources into a snapshot.
///
/// Every dialect-specific decision — what `Int64` is called, whether `Bool` is
/// a type at all — is made here, once, so that everything downstream compares
/// SQL against SQL.
pub fn snapshot_of(
  specs : Array[@gen.EntitySpec],
  dialect~ : @aya.Dialect,
) -> Snapshot raise DdlError {
  let tables : Array[TableDef] = []
  for spec in specs {
    if tables.search_by(t => t.name == spec.table) is Some(_) {
      raise DuplicateTable(table=spec.table)
    }
    tables.push(table_of(spec, dialect))
  }
  tables.sort_by((x, y) => lex_compare(x.name, y.name))
  { version: SNAPSHOT_VERSION, dialect, tables }
}

///|
fn table_of(
  spec : @gen.EntitySpec,
  dialect : @aya.Dialect,
) -> TableDef raise DdlError {
  let columns : Array[ColumnDef] = []
  for f in spec.fields {
    columns.push(column_of(f, spec.table, dialect))
  }
  let indexes = spec.indexes.map(i => IndexDef::{
    name: i.name,
    columns: i.columns,
    unique: i.unique,
  })
  indexes.sort_by((x, y) => lex_compare(x.name, y.name))
  { name: spec.table, columns, indexes }
}

///|
fn column_of(
  f : @gen.FieldSpec,
  table : String,
  dialect : @aya.Dialect,
) -> ColumnDef raise DdlError {
  let ty = match f.sql_type {
    Some(t) => t
    None =>
      match infer_sql_type(f.ty, dialect) {
        Some(t) => t
        None => raise UnknownColumnType(table~, column=f.column, ty=f.ty)
      }
  }
  {
    name: f.column,
    ty,
    // A primary key is NOT NULL even when SQLite would tolerate otherwise:
    // the row type says the field is always there, and the schema should not
    // quietly permit a row the decoder cannot read.
    not_null: !f.nullable || f.is_primary,
    primary_key: f.is_primary,
    autoincrement: f.autoincrement,
    unique: f.unique,
    default_sql: f.default_sql,
    references: f.references.map(r => ForeignKey::{
      table: r.table,
      column: r.column,
      on_delete: r.on_delete,
      on_update: r.on_update,
    }),
  }
}

///|
/// Map a MoonBit type to its column type, for the types aya can store.
///
/// The table is deliberately no wider than `SqlValue`: a type that is not one
/// of these has to state its storage with `#aya.column(type="...")`, because
/// guessing what a wrapper type wraps is how a domain `UserId` ends up in a
/// TEXT column.
pub fn infer_sql_type(ty : String, dialect : @aya.Dialect) -> String? {
  let base = if ty.has_suffix("?") {
    ty[:ty.length() - 1].to_owned()
  } else {
    ty
  }
  match (base, dialect) {
    ("Int", Sqlite) | ("Int64", Sqlite) | ("Bool", Sqlite) => Some("INTEGER")
    ("Double", Sqlite) => Some("REAL")
    ("String", Sqlite) => Some("TEXT")
    ("Bytes", Sqlite) => Some("BLOB")
    ("Int", Postgres) => Some("INTEGER")
    ("Int64", Postgres) => Some("BIGINT")
    ("Bool", Postgres) => Some("BOOLEAN")
    ("Double", Postgres) => Some("DOUBLE PRECISION")
    ("String", Postgres) => Some("TEXT")
    ("Bytes", Postgres) => Some("BYTEA")
    _ => None
  }
}

///|
/// Compare two names the way a reader expects.
///
/// MoonBit's `Compare for String` is shortlex — it orders by length first — so
/// sorting a snapshot with it puts `users` before `accounts`. That is stable,
/// but a snapshot is read in review, and a table list that is not alphabetical
/// looks like it is in no order at all.
fn lex_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let order = a[i].compare(b[i])
    if order != 0 {
      return order
    }
  }
  a.length().compare(b.length())
}
