///|
/// A SELECT under construction, together with what its rows decode to.
///
/// `Cols` is the column handles the combinators are written against — one
/// table's `Cols` struct to begin with, a tuple once joins are added. `A` is
/// what a row becomes, which is the table's entity until `map` says otherwise.
pub struct Query[Cols, A] {
  source : String
  source_tbl : String
  joins : Array[Join]
  cols : Cols
  projection : Array[RawExpr]
  wheres : Array[RawExpr]
  group : Array[RawExpr]
  order : Array[OrderKey]
  limit_n : Int?
  decode : (Row) -> A raise DecodeError
}

///|
/// Start a query from a table, selecting every column it declares.
pub fn[C, R] from(t : Table[C, R]) -> Query[C, R] {
  {
    source: t.table_name,
    source_tbl: t.tbl,
    joins: [],
    cols: t.cols,
    projection: t.all.exprs.copy(),
    wheres: [],
    group: [],
    order: [],
    limit_n: None,
    decode: t.all.read,
  }
}

///|
/// Rebuild a query around a new projection, decoder and set of column handles.
///
/// The four combinators that change what a query yields — `map`, `map_cols`,
/// `reduce` and `group_by` — each change some of `cols`, `projection`, `group`
/// and `decode`, and none of the rest. They cannot say `{ ..self, .. }`
/// because the result's type parameters differ from the source's, so the part
/// they share is spelled here once instead of four times.
fn[C, A, D, B] Query::respec(
  self : Query[C, A],
  cols~ : D,
  projection~ : Array[RawExpr],
  group~ : Array[RawExpr],
  decode~ : (Row) -> B raise DecodeError,
) -> Query[D, B] {
  {
    source: self.source,
    source_tbl: self.source_tbl,
    joins: self.joins,
    cols,
    projection,
    wheres: self.wheres,
    group,
    order: self.order,
    limit_n: self.limit_n,
    decode,
  }
}

///|
/// Narrow the result. Conditions accumulate and are ANDed together.
pub fn[C, A] Query::filter(
  self : Query[C, A],
  f : (C) -> Expr[Bool],
) -> Query[C, A] {
  let wheres = self.wheres.copy()
  wheres.push(f(self.cols).raw())
  { ..self, wheres, }
}

///|
/// Replace the projection, and with it what a row decodes to.
pub fn[C, R, O] Query::map(
  self : Query[C, R],
  f : (C) -> Selection[O],
) -> Query[C, O] {
  let s = f(self.cols)
  self.respec(
    cols=self.cols,
    projection=s.exprs.copy(),
    group=self.group,
    decode=s.read,
  )
}

///|
/// Replace the column handles the query carries.
///
/// Chained joins nest their columns to the left — `((C1, C2), C3)` — and
/// indexing through that nesting at every later step reads badly. Collapsing
/// it once, into a flat tuple or a struct with names, keeps the rest of the
/// pipeline legible. Only the handles change; the SQL built so far does not.
pub fn[C, D, A] Query::map_cols(
  self : Query[C, A],
  f : (C) -> D,
) -> Query[D, A] {
  self.respec(
    cols=f(self.cols),
    projection=self.projection,
    group=self.group,
    decode=self.decode,
  )
}

///|
/// Collapse the whole result into one summary row.
///
/// The projection becomes the aggregates and nothing else, which is why a
/// `Reducer` rather than a `Selection` is asked for here: it cannot smuggle in
/// a bare column that SQL would then refuse to project.
pub fn[C, A, S] Query::reduce(
  self : Query[C, A],
  f : (C) -> Reducer[S],
) -> Query[C, S] {
  let r = f(self.cols).selection()
  self.respec(
    cols=self.cols,
    projection=r.exprs.copy(),
    group=[],
    decode=r.read,
  )
}

///|
/// Summarise one group per distinct key.
///
/// The grouping column is the only non-aggregate the projection can contain,
/// and it is exactly the one being grouped by, so the result is always a legal
/// aggregate query.
pub fn[C, A, K : SqlDecode, S] Query::group_by(
  self : Query[C, A],
  key : (C) -> Column[K],
  f : (C) -> Reducer[S],
) -> Query[C, (K, S)] {
  let k = key(self.cols)
  let r = f(self.cols).selection()
  let name = k.name
  let projection = [k.raw()]
  projection.push_iter(r.exprs.iter())
  self.respec(cols=self.cols, projection~, group=[k.raw()], decode=row => {
    (SqlDecode::decode(row[0], name), (r.read)(row[1:]))
  })
}

///|
/// Sort the result. The last call wins; keys are not accumulated.
pub fn[C, A] Query::order_by(
  self : Query[C, A],
  f : (C) -> Array[OrderKey],
) -> Query[C, A] {
  { ..self, order: f(self.cols) }
}

///|
/// Cap how many rows come back.
pub fn[C, A] Query::limit(self : Query[C, A], n : Int) -> Query[C, A] {
  { ..self, limit_n: Some(n) }
}

///|
/// Build the statement text and its parameters, in placeholder order.
pub fn[C, A] Query::to_sql(
  self : Query[C, A],
  dialect? : Dialect = Dialect::Sqlite,
) -> (String, Array[SqlValue]) raise StatementError {
  self.check_aliases()
  let em = Emitter::new(dialect)
  let buf = StringBuilder::new()
  buf.write_string("SELECT " + self.select_list(em))
  buf.write_string("\n  FROM \"\{self.source}\" AS \{self.source_tbl}")
  for j in self.joins {
    buf.write_string(
      "\n  \{j.kind} \"\{j.table_name}\" AS \{j.tbl} ON \{em.expr(j.on)}",
    )
  }
  buf.write_string(em.where_clause(self.wheres, indent=" "))
  if self.group.length() > 0 {
    buf.write_string(
      "\n GROUP BY " + self.group.map(g => em.expr(g)).join(", "),
    )
  }
  if self.order.length() > 0 {
    let keys = self.order.map(k => "\{em.expr(k.expr)} \{k.dir}")
    buf.write_string("\n ORDER BY " + keys.join(", "))
  }
  if self.limit_n is Some(n) {
    buf.write_string("\n LIMIT \{em.param(VInt(n.to_int64()))}")
  }
  (buf.to_string(), em.params)
}

///|
/// Every table in one query needs its own alias, otherwise `u."id"` silently
/// refers to whichever of them the database picks.
fn[C, A] Query::check_aliases(self : Query[C, A]) -> Unit raise StatementError {
  let seen = [self.source_tbl]
  for j in self.joins {
    guard !seen.contains(j.tbl) else { raise DuplicateAlias(tbl=j.tbl) }
    seen.push(j.tbl)
  }
}

///|
/// Write the SELECT list: one SQL column per projected column, in order.
///
/// Each projected expression is rendered exactly once. `Emitter::expr` appends
/// any literal it meets to the parameter list, so a second rendering would bind
/// the same value twice and shift every later placeholder.
fn[C, A] Query::select_list(self : Query[C, A], em : Emitter) -> String {
  self.projection.map(p => em.expr(p)).join(", ")
}
