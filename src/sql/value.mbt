///|
/// Contains values that can be sent and received to/from the database
pub(all) enum SqlValue {
  VNull
  VInt(Int64)
  VDouble(Double)
  VText(String)
  VBool(Bool)
  VBytes(Bytes)
} derive(Debug, Eq)

///|
/// SQL dialect. The format of placeholders is different.
pub(all) enum Dialect {
  Sqlite
  Postgres
} derive(Debug, Eq)

///|
pub(all) suberror DecodeError {
  MissingColumn(String)
  TypeMismatch(column~ : String, expected~ : String)
  Malformed(String)
} derive(Debug)

///|
pub(open) trait SqlEncode {
  fn to_sql_value(Self) -> SqlValue
}

///|
/// Marker trait for types that can be compared in SQL. for gt, gte, lt, lte, asc, desc.
pub(open) trait SqlOrd {}

///|
pub impl SqlEncode for Int with fn to_sql_value(self) {
  VInt(self.to_int64())
}

///|
pub impl SqlEncode for Int64 with fn to_sql_value(self) {
  VInt(self)
}

///|
pub impl SqlEncode for String with fn to_sql_value(self) {
  VText(self)
}

///|
pub impl SqlEncode for Bool with fn to_sql_value(self) {
  VBool(self)
}

///|
pub impl SqlEncode for Double with fn to_sql_value(self) {
  VDouble(self)
}

///|
/// A nullable column writes `NULL` for `None`.
///
/// The mirror of the `SqlDecode for T?` instance: without it, an entity with
/// any optional field cannot be inserted.
pub impl[T : SqlEncode] SqlEncode for T? with fn to_sql_value(self) {
  match self {
    None => VNull
    Some(x) => SqlEncode::to_sql_value(x)
  }
}

///|
/// A nullable column is still orderable and comparable.
///
/// SQL happily sorts by a column that holds NULLs, so refusing `T?` here would
/// reject ordinary queries like `ORDER BY submitted_at DESC`.
pub impl[T : SqlOrd] SqlOrd for T?

///|
pub impl SqlOrd for Int

///|
pub impl SqlOrd for Int64

///|
pub impl SqlOrd for String

///|
pub impl SqlOrd for Double
