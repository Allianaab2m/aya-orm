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
/// `Cols` becomes a tuple, so a later `filter` or `map` reaches the left
/// table through `.0` and the right one through `.1`. Chaining a third join
/// nests further: `((C1, C2), C3)`.
pub fn[C1, C2, R2, A] Query::join(
  self : Query[C1, A],
  t : Table[C2, R2],
  on : (C1, C2) -> Expr[Bool],
) -> Query[(C1, C2), A] {
  join_with(self, t, on, Inner)
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
/// Join another table, keeping left rows that have no match.
///
/// The right side arrives as `Nullable[C2, R2]` rather than `C2`, so its
/// columns cannot be read as if the join had matched.
pub fn[C1, C2, R2, A] Query::left_join(
  self : Query[C1, A],
  t : Table[C2, R2],
  on : (C1, C2) -> Expr[Bool],
) -> Query[(C1, Nullable[C2, R2]), A] {
  let joins = Array::from_iter(self.joins.iter())
  joins.push({
    kind: Left,
    table_name: t.table_name,
    tbl: t.tbl,
    on: on(self.cols, t.cols).raw(),
  })
  {
    source: self.source,
    source_tbl: self.source_tbl,
    joins,
    cols: (self.cols, Nullable(t.cols, t.all)),
    projection: Array::from_iter(self.projection.iter()),
    wheres: Array::from_iter(self.wheres.iter()),
    order: Array::from_iter(self.order.iter()),
    limit_n: self.limit_n,
    decode: self.decode,
  }
}

///|
fn[C1, C2, R2, A] join_with(
  q : Query[C1, A],
  t : Table[C2, R2],
  on : (C1, C2) -> Expr[Bool],
  kind : JoinKind,
) -> Query[(C1, C2), A] {
  let joins = Array::from_iter(q.joins.iter())
  joins.push({
    kind,
    table_name: t.table_name,
    tbl: t.tbl,
    on: on(q.cols, t.cols).raw(),
  })
  {
    source: q.source,
    source_tbl: q.source_tbl,
    joins,
    cols: (q.cols, t.cols),
    projection: Array::from_iter(q.projection.iter()),
    wheres: Array::from_iter(q.wheres.iter()),
    order: Array::from_iter(q.order.iter()),
    limit_n: q.limit_n,
    decode: q.decode,
  }
}

///|
/// Reinterpret a column as nullable.
///
/// The right-hand side of a LEFT JOIN can be absent, so its columns decode as
/// `T?` even though the entity declares them as `T`.
pub fn[T] Column::nullable(self : Column[T]) -> Column[T?] {
  Column::new(tbl=self.tbl(), name=self.name())
}
