///|
/// An UPDATE statement over one table.
///
/// `Cols` is carried so that assignments and predicates are written against
/// the same typed column handles the query builder uses.
pub struct Update[Cols] {
  table_name : String
  tbl : String
  cols : Cols
  sets : Array[(String, RawExpr)]
  wheres : Array[RawExpr]
}

///|
/// Update the rows matching `pred`.
///
/// The predicate is a required argument rather than a chained step, so an
/// UPDATE that touches the whole table cannot be written by forgetting one.
pub fn[C, R] update(t : Table[C, R], pred : (C) -> Expr[Bool]) -> Update[C] {
  {
    table_name: t.table_name,
    tbl: t.tbl,
    cols: t.cols,
    sets: [],
    wheres: [pred(t.cols).raw()],
  }
}

///|
/// Update every row in the table.
///
/// Named separately from `update` so that an unfiltered write is visible at
/// the call site instead of being an omission.
pub fn[C, R] update_all(t : Table[C, R]) -> Update[C] {
  { table_name: t.table_name, tbl: t.tbl, cols: t.cols, sets: [], wheres: [] }
}

///|
/// Assign a value to one column.
///
/// The column is selected from the table's column handles, so the value type
/// has to match the column type.
pub fn[C, T : SqlEncode] Update::set(
  self : Update[C],
  f : (C) -> Column[T],
  v : T,
) -> Update[C] {
  let sets = self.sets.copy()
  sets.push((f(self.cols).name, Lit(SqlEncode::to_sql_value(v))))
  { ..self, sets, }
}

///|
/// Narrow an update further. Conditions are ANDed together.
pub fn[C] Update::filter(self : Update[C], f : (C) -> Expr[Bool]) -> Update[C] {
  let wheres = self.wheres.copy()
  wheres.push(f(self.cols).raw())
  { ..self, wheres, }
}

///|
pub fn[C] Update::to_sql(
  self : Update[C],
  dialect? : Dialect = Dialect::Sqlite,
) -> (String, Array[SqlValue]) raise StatementError {
  guard self.sets.length() > 0 else { raise EmptyUpdate(table=self.table_name) }
  let em = Emitter::new(dialect)
  let buf = StringBuilder::new()
  buf.write_string("UPDATE \"\{self.table_name}\" AS \{self.tbl}")
  // SET comes before WHERE in the statement, so its parameters must be
  // emitted first to keep the parameter list in textual order.
  let assignments = self.sets.map(pair => {
    let (name, value) = pair
    "\"\{name}\" = \{em.expr(value)}"
  })
  buf.write_string("\n    SET " + assignments.join(", "))
  buf.write_string(em.where_clause(self.wheres, indent="  "))
  (buf.to_string(), em.params)
}
