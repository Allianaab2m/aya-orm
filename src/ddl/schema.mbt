///|
/// Version stamped into every snapshot file.
///
/// Bumped when the JSON shape changes, so an old snapshot is rejected with a
/// clear message instead of being half-understood by a newer generator.
pub const SNAPSHOT_VERSION = "1"

///|
/// The database schema as aya understands it, at one point in time.
///
/// This is the artefact that gets committed next to the migration it belongs
/// to: the next `generate` diffs against it rather than against the database,
/// so generating a migration needs no connection.
pub struct Snapshot {
  version : String
  dialect : @aya.Dialect
  /// Sorted by name, so that reordering entity files cannot produce a diff.
  tables : Array[TableDef]
} derive(Debug, Eq)

///|
pub struct TableDef {
  name : String
  /// Declaration order, which is the order `CREATE TABLE` will use.
  columns : Array[ColumnDef]
  /// Sorted by name.
  indexes : Array[IndexDef]
} derive(Debug, Eq)

///|
/// One column, with its type already resolved for the snapshot's dialect.
///
/// The snapshot stores SQL, not MoonBit: two dialects disagree about what
/// `Int64` is called, and the diff has to compare what the database will
/// actually hold.
pub struct ColumnDef {
  name : String
  ty : String
  not_null : Bool
  primary_key : Bool
  autoincrement : Bool
  unique : Bool
  /// Raw SQL expression, emitted verbatim after `DEFAULT`.
  default_sql : String?
  references : ForeignKey?
} derive(Debug, Eq)

///|
pub struct ForeignKey {
  table : String
  column : String
  on_delete : String?
  on_update : String?
} derive(Debug, Eq)

///|
pub struct IndexDef {
  name : String
  columns : Array[String]
  unique : Bool
} derive(Debug, Eq)

///|
pub(all) suberror DdlError {
  /// Two entities claim the same table name.
  DuplicateTable(table~ : String)
  /// A column's MoonBit type has no built-in SQL mapping and the field did not
  /// say what it stores.
  UnknownColumnType(table~ : String, column~ : String, ty~ : String)
  /// The requested dialect cannot be used for what was asked.
  UnsupportedDialect(dialect~ : String, reason~ : String)
  /// The change is valid SQL nowhere, or valid only against an empty table.
  UnsafeChange(table~ : String, reason~ : String)
  /// A snapshot file could not be read.
  BadSnapshot(reason~ : String)
} derive(Debug)

///|
/// An empty schema: what the first migration is diffed against.
pub fn Snapshot::empty(dialect : @aya.Dialect) -> Snapshot {
  { version: SNAPSHOT_VERSION, dialect, tables: [] }
}

///|
pub fn Snapshot::table(self : Snapshot, name : String) -> TableDef? {
  match self.tables.search_by(t => t.name == name) {
    Some(i) => Some(self.tables[i])
    None => None
  }
}

///|
pub fn TableDef::column(self : TableDef, name : String) -> ColumnDef? {
  match self.columns.search_by(c => c.name == name) {
    Some(i) => Some(self.columns[i])
    None => None
  }
}

///|
pub fn TableDef::index(self : TableDef, name : String) -> IndexDef? {
  match self.indexes.search_by(i => i.name == name) {
    Some(i) => Some(self.indexes[i])
    None => None
  }
}

///|
/// The name a dialect goes by in config files and snapshots.
pub fn dialect_name(d : @aya.Dialect) -> String {
  match d {
    Sqlite => "sqlite"
    Postgres => "postgres"
  }
}

///|
/// Parse a dialect name, rejecting anything aya does not model.
pub fn dialect_of_name(name : String) -> @aya.Dialect raise DdlError {
  match name {
    "sqlite" => Sqlite
    "postgres" | "postgresql" | "pg" => Postgres
    _ =>
      raise UnsupportedDialect(
        dialect=name,
        reason="known dialects are `sqlite` and `postgres`",
      )
  }
}

///|
/// A sentence, not a constructor dump.
///
/// These errors are read by whoever ran `aya-kit`, usually right after they
/// changed an entity, so the message says what to change back.
pub impl Show for DdlError with fn output(self, logger) {
  logger.write_string(
    match self {
      DuplicateTable(table~) => "two entities both map to table `\{table}`"
      UnknownColumnType(table~, column~, ty~) =>
        "\{table}.\{column}: no built-in SQL type for `\{ty}`; add `#aya.column(type=\"...\")` to say what it stores"
      UnsupportedDialect(dialect~, reason~) => "dialect `\{dialect}`: \{reason}"
      UnsafeChange(table~, reason~) => "table `\{table}`: \{reason}"
      BadSnapshot(reason~) => "snapshot: \{reason}"
    },
  )
}
