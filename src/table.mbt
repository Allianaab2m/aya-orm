///|
/// One result row, as the driver handed it back: the projected values in
/// projection order, and nothing else. Columns are found by position, never by
/// name.
pub type Row = ArrayView[SqlValue]

///|
/// A table, with everything needed to read from it and write to it.
///
/// `Cols` is the struct of `Column[T]` handles the query combinators are
/// written against; `R` is what one row is, which may be the generated row
/// type or a domain type mapped onto it by `table_of`.
///
/// `tbl` is the alias the emitted SQL uses (`FROM "users" AS u`). It is fixed
/// per table rather than assigned per query, which is why a self-join is not
/// expressible yet: both sides would claim the same alias, and `Query::to_sql`
/// raises `DuplicateAlias` rather than emit ambiguous column references.
pub struct Table[Cols, R] {
  table_name : String
  tbl : String
  cols : Cols
  /// Every column, in declaration order.
  all : Selection[R]
  /// The write-side mirror of `all`.
  write : Binding[R]
}

///|
/// Assemble a table from its parts. Normally emitted by `aya-kit` rather
/// than written by hand.
pub fn[C, R] Table::new(
  table_name~ : String,
  tbl~ : String,
  cols~ : C,
  all~ : Selection[R],
  write~ : Binding[R],
) -> Table[C, R] {
  { table_name, tbl, cols, all, write }
}
