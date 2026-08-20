///|
pub(all) enum JoinKind {
  Inner
  Left
} derive(Debug, Eq)

///|
pub impl Show for JoinKind with fn to_string(self) -> String {
  match self {
    Inner => "JOIN"
    Left => "LEFT JOIN"
  }
}

///|
/// One table joined onto a query, with the condition that attaches it.
pub struct Join {
  kind : JoinKind
  table_name : String
  tbl : String
  on : RawExpr
}

///|
/// Join another table, pairing the two tables' column handles.
///
/// `Cols` becomes a pair. Chaining nests to the left — `((C1, C2), C3)` — which
/// `Query::map_cols` collapses into names once the joins are done.
pub fn[C1, C2, R2, A] Query::join(
  self : Query[C1, A],
  t : Table[C2, R2],
  on : (C1, C2) -> Expr[Bool],
) -> Query[(C1, C2), A] {
  attach(self, t, on(self.cols, t.cols).raw(), (self.cols, t.cols), Inner)
}

///|
/// Assemble the joined query. Only the join list and the column handles change.
fn[C1, C2, R2, A, D] attach(
  q : Query[C1, A],
  t : Table[C2, R2],
  on : RawExpr,
  cols : D,
  kind : JoinKind,
) -> Query[D, A] {
  let joins = Array::from_iter(q.joins.iter())
  joins.push({ kind, table_name: t.table_name, tbl: t.tbl, on })
  {
    source: q.source,
    source_tbl: q.source_tbl,
    joins,
    cols,
    projection: Array::from_iter(q.projection.iter()),
    wheres: Array::from_iter(q.wheres.iter()),
    group: Array::from_iter(q.group.iter()),
    order: Array::from_iter(q.order.iter()),
    limit_n: q.limit_n,
    decode: q.decode,
  }
}

///|
/// The right-hand side of a LEFT JOIN.
///
/// Wrapping the joined table's column handles rather than exposing them keeps
/// the nullability from being lost: there is no way to reach a `Column[T]` of
/// an outer-joined table, only a `Column[T?]` through `col`, or the whole row
/// as `Selection[R?]` through `row`.
struct Nullable[C, R](C, Selection[R])

///|
/// Take one column of the outer-joined table, as a nullable column.
pub fn[C, R, T] Nullable::col(
  self : Nullable[C, R],
  f : (C) -> Column[T],
) -> Column[T?] {
  let Nullable(cols, _) = self
  f(cols).nullable()
}

///|
/// Take the whole outer-joined row, absent when nothing matched.
///
/// This is usually what a LEFT JOIN means: not that each column independently
/// might be NULL, but that the row on the right either exists or does not.
/// Inside `Some`, every field keeps the type the table declared.
pub fn[C, R] Nullable::row(self : Nullable[C, R]) -> Selection[R?] {
  let Nullable(_, all) = self
  all.optional()
}

///|
/// Outer-join another table, pairing the column handles.
/// `on` sees the joined table's raw columns, because a join condition is
/// evaluated before the outer-join padding and nullability does not apply to
/// it. What the query carries afterwards is the `Nullable` wrapper.
pub fn[C1, C2, R2, A] Query::left_join(
  self : Query[C1, A],
  t : Table[C2, R2],
  on : (C1, C2) -> Expr[Bool],
) -> Query[(C1, Nullable[C2, R2]), A] {
  attach(
    self,
    t,
    on(self.cols, t.cols).raw(),
    (self.cols, Nullable(t.cols, t.all)),
    Left,
  )
}

///|
/// Reinterpret a column as nullable.
///
/// The right-hand side of a LEFT JOIN can be absent, so its columns decode as
/// `T?` even though the entity declares them as `T`.
pub fn[T] Column::nullable(self : Column[T]) -> Column[T?] {
  Column::new(tbl=self.tbl(), name=self.name())
}

// Destructuring the joined columns.
//
// Chained joins nest their column handles to the left, and MoonBit has no
// pattern in a lambda parameter to take them apart with. These adapters do it
// instead: they turn a function of N named arguments into the single-argument
// function the combinators expect, so `.0.0` lives here and not in user code.

///|
/// Take a two-table join apart into its two column sets.
///
///   |> Query::filter(split2((u, p) => u.age.gte(18) & p.title.ne("draft")))
///
/// Deliberately stops at two. With three tables the arguments start needing
/// positional `_` placeholders, at which point naming the shape with
/// `Query::map_cols` reads better than destructuring it.
pub fn[A, B, R] split2(f : (A, B) -> R) -> ((A, B)) -> R {
  t => f(t.0, t.1)
}
