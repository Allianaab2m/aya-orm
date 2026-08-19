///|
/// A row in a table is represented as a map from column names to values.
pub type Row = ArrayView[SqlValue]

///|
/// Table definition. A table has a name and a list of columns.
pub struct Table[Cols, R] {
  table_name : String
  tbl : String
  cols : Cols
  all : Selection[R]
  write : Binding[R]
}

///|
pub fn[C, R] Table::new(
  table_name~ : String,
  tbl~ : String,
  cols~ : C,
  all~ : Selection[R],
  write~ : Binding[R],
) -> Table[C, R] {
  { table_name, tbl, cols, all, write }
}
