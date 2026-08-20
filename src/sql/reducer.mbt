///|
/// A summary computed across many rows, and how to read it back.
///
/// Structurally this is a `Selection` — the same expressions-plus-positional-
/// reader pair — but the type is deliberately separate and opaque: a `Reducer`
/// may only hold aggregate expressions, and there is no constructor that could
/// put anything else in one. That is what stops a bare column being projected
/// alongside an aggregate without being grouped by. SQL rejects such a query,
/// and here it cannot be written.
struct Reducer[Out](Selection[Out])

///|
/// The projection underneath, for the query builder to splice in.
///
/// Kept private: handing a `Reducer` back out as a `Selection` would undo the
/// separation the type exists for.
fn[Out] Reducer::selection(self : Reducer[Out]) -> Selection[Out] {
  let Reducer(s) = self
  s
}

///|
/// One aggregate call over one optional argument, read back with `T`'s decoder.
///
/// `key` is the name a decode failure is reported against, which is the
/// column's for a column aggregate and the function's for `COUNT(*)`.
fn[T : SqlDecode] agg(f : String, arg : RawExpr?, key~ : String) -> Reducer[T] {
  Reducer(Selection::new([Agg(f, arg)], row => SqlDecode::decode(row[0], key)))
}

///|
/// How many rows there are.
///
/// Unlike the others this never comes back empty: `COUNT(*)` over no rows is
/// zero, where `MIN` over no rows is NULL.
pub fn count() -> Reducer[Int] {
  agg("COUNT", None, key="count")
}

///|
/// How many rows have a value in this column. NULLs are not counted.
pub fn[T] count_of(c : Column[T]) -> Reducer[Int] {
  agg("COUNT", Some(c.raw()), key="count")
}

///|
/// The smallest value, or nothing when there are no rows.
pub fn[T : SqlDecode + SqlOrd] min(c : Column[T]) -> Reducer[T?] {
  agg("MIN", Some(c.raw()), key=c.name)
}

///|
/// The largest value, or nothing when there are no rows.
pub fn[T : SqlDecode + SqlOrd] max(c : Column[T]) -> Reducer[T?] {
  agg("MAX", Some(c.raw()), key=c.name)
}

///|
/// The total, or nothing when there are no rows.
pub fn[T : SqlDecode + SqlNum] sum(c : Column[T]) -> Reducer[T?] {
  agg("SUM", Some(c.raw()), key=c.name)
}

///|
/// The mean, or nothing when there are no rows.
///
/// The result is a `Double` whatever the column's type, because an average of
/// integers is not generally an integer.
pub fn[T : SqlNum] avg(c : Column[T]) -> Reducer[Double?] {
  agg("AVG", Some(c.raw()), key=c.name)
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
  Reducer(self.selection().zip(other.selection()))
}

///|
/// Reshape a summary once it has been read.
pub fn[A, B] Reducer::map(
  self : Reducer[A],
  f : (A) -> B raise DecodeError,
) -> Reducer[B] {
  Reducer(self.selection().map(f))
}
