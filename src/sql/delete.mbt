///|
/// A DELETE statement over one table.
pub struct Delete[Cols] {
  table_name : String
  tbl : String
  cols : Cols
  wheres : Array[RawExpr]
}

///|
/// Delete the rows matching `pred`.
///
/// As with `update`, the predicate is required so that a table-wide delete
/// cannot happen by omission.
pub fn[C, R] delete(t : Table[C, R], pred : (C) -> Expr[Bool]) -> Delete[C] {
  {
    table_name: t.table_name,
    tbl: t.tbl,
    cols: t.cols,
    wheres: [pred(t.cols).raw()],
  }
}

///|
/// Delete every row in the table.
pub fn[C, R] delete_all(t : Table[C, R]) -> Delete[C] {
  { table_name: t.table_name, tbl: t.tbl, cols: t.cols, wheres: [] }
}

///|
/// Narrow a delete further. Conditions are ANDed together.
pub fn[C] Delete::filter(self : Delete[C], f : (C) -> Expr[Bool]) -> Delete[C] {
  let wheres = self.wheres.copy()
  wheres.push(f(self.cols).raw())
  { ..self, wheres, }
}

///|
pub fn[C] Delete::to_sql(
  self : Delete[C],
  dialect? : Dialect = Dialect::Sqlite,
) -> (String, Array[SqlValue]) {
  let em = Emitter::new(dialect)
  let buf = StringBuilder::new()
  buf.write_string("DELETE FROM \"\{self.table_name}\" AS \{self.tbl}")
  buf.write_string(em.where_clause(self.wheres, indent="  "))
  (buf.to_string(), em.params)
}
