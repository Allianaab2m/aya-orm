///|
pub struct Query[Cols, A] {
  source : String
  source_tbl : String
  joins : Array[Join]
  cols : Cols
  projection : Array[RawExpr]
  wheres : Array[RawExpr]
  order : Array[OrderKey]
  limit_n : Int?
  decode : (Row) -> A raise DecodeError
}

///|
pub fn[C, R] from(t : Table[C, R]) -> Query[C, R] {
  {
    source: t.table_name,
    source_tbl: t.tbl,
    joins: [],
    cols: t.cols,
    projection: Array::from_iter(t.all.exprs.iter()),
    wheres: [],
    order: [],
    limit_n: None,
    decode: t.all.read,
  }
}

///|
pub fn[C, A] Query::filter(
  self : Query[C, A],
  f : (C) -> Expr[Bool],
) -> Query[C, A] {
  let wheres = Array::from_iter(self.wheres.iter())
  wheres.push(f(self.cols).raw())

  { ..self, wheres, }
}

///|
pub fn[C, R, O] Query::map(
  self : Query[C, R],
  f : (C) -> Selection[O],
) -> Query[C, O] {
  let s = f(self.cols)
  {
    source: self.source,
    source_tbl: self.source_tbl,
    joins: Array::from_iter(self.joins.iter()),
    cols: self.cols,
    projection: Array::from_iter(s.exprs.iter()),
    wheres: Array::from_iter(self.wheres.iter()),
    order: Array::from_iter(self.order.iter()),
    limit_n: self.limit_n,
    decode: s.read,
  }
}

///|
pub fn[C, A] Query::order_by(
  self : Query[C, A],
  f : (C) -> Array[OrderKey],
) -> Query[C, A] {
  { ..self, order: f(self.cols) }
}

///|
pub fn[C, A] Query::limit(self : Query[C, A], n : Int) -> Query[C, A] {
  { ..self, limit_n: Some(n) }
}

///|
pub fn[C, A] Query::to_sql(
  self : Query[C, A],
  dialect? : Dialect = Dialect::Sqlite,
  shape? : RowShape = RowShape::Plain,
) -> (String, Array[SqlValue]) raise StatementError {
  // Every table in the query must have its own alias, otherwise `u."id"`
  // silently refers to whichever one the database picks.
  let seen = [self.source_tbl]
  for j in self.joins {
    if seen.contains(j.tbl) {
      raise DuplicateAlias(tbl=j.tbl)
    }
    seen.push(j.tbl)
  }
  let em = Emitter::new(dialect)
  let buf = StringBuilder::new()

  let select = join(
    self.projection.map(p => {
      // Rendered once and used twice on purpose: `Emitter::expr` appends any
      // literal it meets to the parameter list, so rendering a second time
      // would bind the same value twice and shift every later placeholder.
      let e = em.expr(p)
      match shape {
        Plain => e
        Typed => "typeof(\{e}), \{e}"
      }
    }),
    ", ",
  )
  buf.write_string("SELECT \{select}")
  buf.write_string("\n  FROM \"\{self.source}\" AS \{self.source_tbl}")
  for j in self.joins {
    buf.write_string(
      "\n  \{j.kind} \"\{j.table_name}\" AS \{j.tbl} ON \{em.expr(j.on)}",
    )
  }

  if self.wheres.length() > 0 {
    let parts = self.wheres.map(w => em.expr(w))
    buf.write_string("\n WHERE " + join(parts, "\n   AND "))
  }

  if self.order.length() > 0 {
    let keys = self.order.map(k => "\{em.expr(k.expr)} \{k.dir}")
    buf.write_string("\n ORDER BY " + join(keys, ", "))
  }

  match self.limit_n {
    Some(n) => buf.write_string("\n LIMIT \{em.param(VInt(n.to_int64()))}")
    None => ()
  }

  (buf.to_string(), em.params)
}
