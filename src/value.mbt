// Values on the wire, and the traits that move MoonBit types across it.
//
// `SqlEncode` and `SqlDecode` are the two directions. `SqlOrd` and `SqlNum`
// are markers that carry no methods: they exist only to keep an operator from
// being offered on a type SQL cannot apply it to.

///|
/// A value as it travels to or from the database.
pub(all) enum SqlValue {
  VNull
  VInt(Int64)
  VDouble(Double)
  VText(String)
  VBool(Bool)
  VBytes(Bytes)
} derive(Debug, Eq)

///|
/// SQL dialect. The two differ in how a placeholder is spelled.
pub(all) enum Dialect {
  Sqlite
  Postgres
} derive(Debug, Eq)

///|
/// How a driver needs a SELECT list written.
///
/// `Plain` is one SQL column per projected column, and is what a binding that
/// reports a result column's type gives you for nothing.
///
/// `Typed` writes `typeof(e), e` for each projected column instead, so the type
/// and the nullness travel beside the value and the driver folds the pairs back
/// into one `SqlValue` each. It exists because a binding may hand back only a
/// value: ask such a binding for a column as an `Int` and a NULL arrives as
/// `0`, indistinguishable from a real zero. Guessing there would be a silent
/// wrong answer in the middle of an otherwise type-safe path, so the type is
/// asked of the database instead. The spelling is SQLite's, because SQLite is
/// the binding that needs it.
pub(all) enum RowShape {
  Plain
  Typed
} derive(Debug, Eq)

///|
/// A stored value did not fit the type the entity declared for it.
pub(all) suberror DecodeError {
  MissingColumn(String)
  TypeMismatch(column~ : String, expected~ : String)
  Malformed(String)
} derive(Debug)

///|
/// How a MoonBit value is written to a column.
pub(open) trait SqlEncode {
  fn to_sql_value(Self) -> SqlValue
}

///|
/// How a column is read back into a MoonBit value.
///
/// The second argument is the column's name, carried only so that a failure
/// can say which column it came from.
pub(open) trait SqlDecode {
  fn decode(SqlValue, String) -> Self raise DecodeError
}

///|
/// Marker trait for types SQL will order: `gt`, `gte`, `lt`, `lte`, `asc`,
/// `desc`. No methods — it is a constraint, not an interface.
pub(open) trait SqlOrd {}

///|
/// Marker trait for types SQL will do arithmetic on.
///
/// Narrower than `SqlOrd` on purpose: `sum` and `avg` need a number, not
/// merely something orderable, so a `Column[String]` cannot be summed.
pub(open) trait SqlNum {}

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
pub impl SqlDecode for Int with fn decode(v, k) {
  match v {
    VInt(n) => n.to_int()
    _ => raise TypeMismatch(column=k, expected="Int")
  }
}

///|
pub impl SqlDecode for String with fn decode(v, k) {
  match v {
    VText(s) => s
    _ => raise TypeMismatch(column=k, expected="String")
  }
}

///|
/// Numbers arrive as whichever of the two numeric shapes the driver chose, so
/// an integral column read as a `Double` is accepted rather than rejected.
pub impl SqlDecode for Double with fn decode(v, k) {
  match v {
    VDouble(d) => d
    VInt(n) => n.to_double()
    _ => raise TypeMismatch(column=k, expected="Double")
  }
}

///|
pub impl SqlDecode for Bool with fn decode(v, k) {
  match v {
    VBool(b) => b
    VInt(n) => n != 0L
    _ => raise TypeMismatch(column=k, expected="Bool")
  }
}

///|
/// NULL is the absent value; anything else goes through `T`'s own decoder.
pub impl[T : SqlDecode] SqlDecode for T? with fn decode(v, k) {
  match v {
    VNull => None
    other => Some(SqlDecode::decode(other, k))
  }
}

///|
pub impl SqlOrd for Int

///|
pub impl SqlOrd for Int64

///|
pub impl SqlOrd for String

///|
pub impl SqlOrd for Double

///|
/// A nullable column is still orderable and comparable.
///
/// SQL happily sorts by a column that holds NULLs, so refusing `T?` here would
/// reject ordinary queries like `ORDER BY submitted_at DESC`.
pub impl[T : SqlOrd] SqlOrd for T?

///|
pub impl SqlNum for Int

///|
pub impl SqlNum for Int64

///|
pub impl SqlNum for Double
