///|
/// A summary computed across many rows, and how to read it back.
///
/// The runtime shape is the same as `Selection`, but the type is deliberately
/// separate: a `Reducer` may only hold aggregate expressions. That is what
/// stops a bare column being projected alongside an aggregate without being
/// grouped by — SQL rejects such a query, and here it cannot be written.
pub struct Reducer[Out] {
  exprs : Array[RawExpr]
  read : (ArrayView[SqlValue]) -> Out raise DecodeError
}

///|
/// Marker trait for types SQL will do arithmetic on.
///
/// The counterpart of `SqlOrd`: `sum` and `avg` need a number, not merely
/// something orderable, so a `Column[String]` cannot be summed.
pub(open) trait SqlNum {}

///|
pub impl SqlNum for Int

///|
pub impl SqlNum for Int64

///|
pub impl SqlNum for Double

///|
/// How many rows there are.
///
/// Unlike the others this never comes back empty: `COUNT(*)` over no rows is
/// zero, where `MIN` over no rows is NULL.
pub fn count() -> Reducer[Int] {
  {
    exprs: [Agg("COUNT", None)],
    read: row => SqlDecode::decode(row[0], "count"),
  }
}

///|
/// How many rows have a value in this column. NULLs are not counted.
pub fn[T] count_of(c : Column[T]) -> Reducer[Int] {
  {
    exprs: [Agg("COUNT", Some(c.raw()))],
    read: row => SqlDecode::decode(row[0], "count"),
  }
}

///|
/// The smallest value, or nothing when there are no rows.
pub fn[T : SqlDecode + SqlOrd] min(c : Column[T]) -> Reducer[T?] {
  agg1("MIN", c)
}

///|
/// The largest value, or nothing when there are no rows.
pub fn[T : SqlDecode + SqlOrd] max(c : Column[T]) -> Reducer[T?] {
  agg1("MAX", c)
}

///|
/// The total, or nothing when there are no rows.
pub fn[T : SqlDecode + SqlNum] sum(c : Column[T]) -> Reducer[T?] {
  agg1("SUM", c)
}

///|
/// The mean, or nothing when there are no rows.
///
/// The result is a `Double` whatever the column's type, because an average of
/// integers is not generally an integer.
pub fn[T : SqlNum] avg(c : Column[T]) -> Reducer[Double?] {
  {
    exprs: [Agg("AVG", Some(c.raw()))],
    read: row => SqlDecode::decode(row[0], c.name()),
  }
}

///|
/// One aggregate over one column, read back as optional.
fn[T : SqlDecode, U] agg1(f : String, c : Column[U]) -> Reducer[T?] {
  let key = c.name()
  {
    exprs: [Agg(f, Some(c.raw()))],
    read: row => SqlDecode::decode(row[0], key),
  }
}

///|
/// Compute two summaries in the same pass.
///
/// Acadia spells this `map2` through `map9`; `zip` plus `map` covers the same
/// ground without an arity ladder.
pub fn[A, B] Reducer::zip(
  self : Reducer[A],
  other : Reducer[B],
) -> Reducer[(A, B)] {
  let n = self.exprs.length()
  let exprs : Array[RawExpr] = []
  exprs.push_iter(self.exprs.iter())
  exprs.push_iter(other.exprs.iter())
  { exprs, read: row => ((self.read)(row[0:n]), (other.read)(row[n:])) }
}

///|
/// Reshape a summary once it has been read.
pub fn[A, B] Reducer::map(
  self : Reducer[A],
  f : (A) -> B raise DecodeError,
) -> Reducer[B] {
  { exprs: self.exprs, read: row => f((self.read)(row)) }
}
