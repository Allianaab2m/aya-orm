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
/// Doubling the SELECT list must not double the parameters. Each expression is
/// rendered once and its text reused, so a literal in the projection is bound
/// once and every later placeholder keeps its number.
test "a typed projection binds each parameter once" {
  // A literal in the projection is the case that would go wrong: it is the
  // only projected expression that carries a parameter of its own.
  let literal : Selection[String] = Selection::new(
    [RawExpr::Lit(VText("archived"))],
    row => SqlDecode::decode(row[0], "archived"),
  )
  let (sql, params) = (from(probes())
  |> Query::filter(p => p.id.gte(18))
  |> Query::map(_ => literal)
  |> Query::limit(5)).to_sql(shape=Typed)
  inspect(
    sql,
    content=(
      #|SELECT typeof(?), ?
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
