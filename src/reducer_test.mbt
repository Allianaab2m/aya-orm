///|
test "a whole-table summary is one aggregate query" {
  inspect(
    (from(users()) |> Query::reduce(_ => count())).to_sql().0,
    content=(
      #|SELECT COUNT(*)
      #|  FROM "users" AS u
    ),
  )
}

///|
/// `zip` computes several summaries in one pass, which is what an aggregate
/// query does anyway.
test "several summaries share one query" {
  let (sql, params) = (from(users())
  |> Query::filter(u => u.deleted_at.is_none())
  |> Query::reduce(u => count().zip(min(u.age)).zip(max(u.age)))).to_sql()
  inspect(
    sql,
    content=(
      #|SELECT COUNT(*), MIN(u."age"), MAX(u."age")
      #|  FROM "users" AS u
      #| WHERE u."deleted_at" IS NULL
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[]
    ),
  )
}

///|
test "summaries decode into their own types" {
  let q = from(users())
    |> Query::reduce(u => count().zip(min(u.age)).zip(avg(u.age)))
  let row : Row = [
      SqlValue::VInt(3),
      SqlValue::VInt(18),
      SqlValue::VDouble(25.5),
    ][:]
  debug_inspect(
    (q.decode)(row),
    content=(
      #|((3, Some(18)), Some(25.5))
    ),
  )
}

///|
/// An empty table gives no minimum, which is why `min` reads as optional while
/// `count` does not.
test "an empty table has a count but no minimum" {
  let q = from(users()) |> Query::reduce(u => count().zip(min(u.age)))
  let row : Row = [SqlValue::VInt(0), SqlValue::VNull][:]
  debug_inspect(
    (q.decode)(row),
    content=(
      #|(0, None)
    ),
  )
}

///|
test "grouping projects the key alongside the summary" {
  let (sql, _) = (from(users())
  |> Query::group_by(u => u.name, u => count().zip(avg(u.age)))).to_sql()
  inspect(
    sql,
    content=(
      #|SELECT u."name", COUNT(*), AVG(u."age")
      #|  FROM "users" AS u
      #| GROUP BY u."name"
    ),
  )
}

///|
test "a grouped row decodes into key and summary" {
  let q = from(users()) |> Query::group_by(u => u.name, _ => count())
  let row : Row = [SqlValue::VText("alice"), SqlValue::VInt(2)][:]
  debug_inspect(
    (q.decode)(row),
    content=(
      #|("alice", 2)
    ),
  )
}

///|
/// Filters still apply before grouping, and the parameters stay in textual
/// order across the whole statement.
test "filters and limits compose with grouping" {
  let (sql, params) = (from(users())
  |> Query::filter(u => u.age.gte(18))
  |> Query::group_by(u => u.name, _ => count())
  |> Query::limit(10)).to_sql()
  inspect(
    sql,
    content=(
      #|SELECT u."name", COUNT(*)
      #|  FROM "users" AS u
      #| WHERE u."age" >= ?
      #| GROUP BY u."name"
      #| LIMIT ?
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VInt(18), VInt(10)]
    ),
  )
}

///|
/// Aggregates work over a join too: the reducer sees both tables' columns.
test "a summary over a join" {
  inspect(
    (from(users())
    |> Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
    |> Query::group_by(
      split2((u, _p) => u.name),
      split2((_u, p) => count_of(p.id)),
    )).to_sql().0,
    content=(
      #|SELECT u."name", COUNT(p."id")
      #|  FROM "users" AS u
      #|  JOIN "posts" AS p ON u."id" = p."author_id"
      #| GROUP BY u."name"
    ),
  )
}
