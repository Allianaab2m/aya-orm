///|
/// A domain-flavoured identifier rather than a bare `Int`.
///
/// Nothing in cairn requires a column to be primitive: `Column[T]` accepts any
/// `T` that can encode and decode, so the richer type can live in the row type
/// itself instead of behind a mapping layer.
pub(all) struct AccountId(Int) derive(Debug, Eq)

///|
pub impl @sql.SqlEncode for AccountId with fn to_sql_value(self) {
  let AccountId(n) = self
  @sql.SqlEncode::to_sql_value(n)
}

///|
pub impl @sql.SqlDecode for AccountId with fn decode(v, k) {
  AccountId(@sql.SqlDecode::decode(v, k))
}

///|
/// A closed set of states, stored as text.
pub(all) enum Plan {
  Free
  Pro
} derive(Debug, Eq)

///|
pub impl @sql.SqlEncode for Plan with fn to_sql_value(self) {
  match self {
    Free => @sql.SqlValue::VText("free")
    Pro => @sql.SqlValue::VText("pro")
  }
}

///|
/// Decoding is where a domain invariant gets enforced: a value outside the set
/// fails loudly instead of arriving as an untyped string.
pub impl @sql.SqlDecode for Plan with fn decode(v, k) {
  match v {
    VText("free") => Free
    VText("pro") => Pro
    _ => raise @sql.TypeMismatch(column=k, expected="Plan")
  }
}

///|
#cairn.table(name="accounts", alias="a")
pub(all) struct Account {
  #cairn.id
  id : AccountId
  email : String
  plan : Plan
} derive(Debug, Eq)
