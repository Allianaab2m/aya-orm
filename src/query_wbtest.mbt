///|
/// A table with one column, enough to hang a projection on.
fn probes() -> Table[ProbeCols, Int] {
  let cols : ProbeCols = { id: Column::new(tbl="p", name="id") }
  Table::new(
    table_name="probes",
    tbl="p",
    cols~,
    all=sel(cols.id),
    write=Binding::new(["id"], v => [SqlEncode::to_sql_value(v)]),
  )
}

///|
struct ProbeCols {
  id : Column[Int]
}

///|
/// Parameters are collected in the order the clauses are written, and the
/// SELECT list is the first of them. A projected literal must therefore take
/// placeholder 1 and push the WHERE and LIMIT parameters along behind it.
test "a projected literal is bound once, ahead of every later parameter" {
  // A literal in the projection is the case that would go wrong: it is the
  // only projected expression that carries a parameter of its own.
  let literal : Selection[String] = Selection::new(
    [RawExpr::Lit(VText("archived"))],
    row => SqlDecode::decode(row[0], "archived"),
  )
  let (sql, params) = (from(probes())
  |> Query::filter(p => p.id.gte(18))
  |> Query::map(_ => literal)
  |> Query::limit(5)).to_sql()
  inspect(
    sql,
    content=(
      #|SELECT ?
      #|  FROM "probes" AS p
      #| WHERE p."id" >= ?
      #| LIMIT ?
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VText("archived"), VInt(18), VInt(5)]
    ),
  )
}
