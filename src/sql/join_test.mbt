///|
struct PostCols {
  id : Column[Int]
  author_id : Column[Int]
  title : Column[String]
}

///|
struct Post {
  id : Int
  title : String
} derive(Debug, Eq)

///|
fn posts() -> Table[PostCols, Post] {
  let cols : PostCols = {
    id: Column::new(tbl="p", name="id"),
    author_id: Column::new(tbl="p", name="author_id"),
    title: Column::new(tbl="p", name="title"),
  }
  Table::new(
    table_name="posts",
    tbl="p",
    cols~,
    all=sel2(cols.id, cols.title).into2((id, title) => Post::{ id, title }),
    write=Binding::new(["id", "title"], p => {
      [SqlEncode::to_sql_value(p.id), SqlEncode::to_sql_value(p.title)]
    }),
  )
}

///|
test "inner join pairs the two column sets" {
  inspect(
    (from(users())
    |> Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
    |> Query::map(c => sel2(c.0.name, c.1.title))).to_sql().0,
    content=(
      #|SELECT u."name", p."title"
      #|  FROM "users" AS u
      #|  JOIN "posts" AS p ON u."id" = p."author_id"
    ),
  )
}

///|
test "filters after a join reach both tables" {
  let (sql, params) = (from(users())
  |> Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
  |> Query::filter(c => c.0.age.gte(18) & c.1.title.ne("draft"))
  |> Query::map(c => sel2(c.0.name, c.1.title))
  |> Query::order_by(c => [c.1.id.desc()])).to_sql()
  inspect(
    sql,
    content=(
      #|SELECT u."name", p."title"
      #|  FROM "users" AS u
      #|  JOIN "posts" AS p ON u."id" = p."author_id"
      #| WHERE u."age" >= ? AND p."title" <> ?
      #| ORDER BY p."id" DESC
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VInt(18), VText("draft")]
    ),
  )
}

///|
test "left join hands back the right side as nullable" {
  inspect(
    (from(users())
    |> Query::left_join(posts(), (u, p) => u.id.eq_col(p.author_id))
    |> Query::map(c => sel2(c.0.name, c.1.col(p => p.title)))).to_sql().0,
    content=(
      #|SELECT u."name", p."title"
      #|  FROM "users" AS u
      #|  LEFT JOIN "posts" AS p ON u."id" = p."author_id"
    ),
  )
}

///|
/// The whole outer-joined row, absent when nothing matched. Inside `Some` the
/// fields keep the types the table declared.
test "left join can take the right row as a whole" {
  let q = from(users())
    |> Query::left_join(posts(), (u, p) => u.id.eq_col(p.author_id))
    |> Query::map(c => sel(c.0.name).zip(c.1.row()))
  inspect(
    q.to_sql().0,
    content=(
      #|SELECT u."name", p."id", p."title"
      #|  FROM "users" AS u
      #|  LEFT JOIN "posts" AS p ON u."id" = p."author_id"
    ),
  )
  let matched : Row = [
      SqlValue::VText("alice"),
      SqlValue::VInt(7),
      SqlValue::VText("hello"),
    ][:]
  debug_inspect(
    (q.decode)(matched),
    content=(
      #|("alice", Some({ id: 7, title: "hello" }))
    ),
  )
  let unmatched : Row = [
      SqlValue::VText("bob"),
      SqlValue::VNull,
      SqlValue::VNull,
    ][:]
  debug_inspect(
    (q.decode)(unmatched),
    content=(
      #|("bob", None)
    ),
  )
}

///|
test "a third join nests the column tuple" {
  inspect(
    (from(users())
    |> Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
    |> Query::join(tags(), (c, t) => c.1.id.eq_col(t.post_id))
    |> Query::map(c => sel3(c.0.0.name, c.0.1.title, c.1.label))).to_sql().0,
    content=(
      #|SELECT u."name", p."title", t."label"
      #|  FROM "users" AS u
      #|  JOIN "posts" AS p ON u."id" = p."author_id"
      #|  JOIN "tags" AS t ON p."id" = t."post_id"
    ),
  )
}

///|
test "reusing an alias is rejected instead of producing ambiguous SQL" {
  try {
    let _ = (from(users()) |> Query::join(users(), (a, b) => a.id.eq_col(b.id))).to_sql()
    fail("expected DuplicateAlias")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|DuplicateAlias(tbl="u")
        ),
      )
  }
}

///|
struct TagCols {
  post_id : Column[Int]
  label : Column[String]
}

///|
fn tags() -> Table[TagCols, String] {
  let cols : TagCols = {
    post_id: Column::new(tbl="t", name="post_id"),
    label: Column::new(tbl="t", name="label"),
  }
  Table::new(
    table_name="tags",
    tbl="t",
    cols~,
    all=sel(cols.label),
    write=Binding::new(["label"], s => [SqlEncode::to_sql_value(s)]),
  )
}

///|
/// `map_cols` only renames the handles; it does not touch the SQL built so far.
/// Flattening to a tuple is the lightweight option when a struct is overkill.
test "map_cols flattens nested join columns" {
  let nested = from(users())
    |> Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
    |> Query::join(tags(), (c, t) => c.1.id.eq_col(t.post_id))
  let flat = nested |> Query::map_cols(c => (c.0.0, c.0.1, c.1))
  // Same three tables, reached as .0 / .1 / .2 instead of .0.0 / .0.1 / .1
  let a = (nested
  |> Query::filter(c => c.0.0.age.gte(18))
  |> Query::map(c => sel2(c.0.1.title, c.1.label))).to_sql()
  let b = (flat
  |> Query::filter(c => c.0.age.gte(18))
  |> Query::map(c => sel2(c.1.title, c.2.label))).to_sql()
  assert_eq(a.0, b.0)
  inspect(
    b.0,
    content=(
      #|SELECT p."title", t."label"
      #|  FROM "users" AS u
      #|  JOIN "posts" AS p ON u."id" = p."author_id"
      #|  JOIN "tags" AS t ON p."id" = t."post_id"
      #| WHERE u."age" >= ?
    ),
  )
}

///|
/// `split2` supplies the destructuring MoonBit cannot express in a lambda
/// parameter, so a two-table join never has to be indexed into.
test "split2 stands in for lambda destructuring" {
  inspect(
    (from(users())
    |> Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
    |> Query::filter(split2((u, p) => u.age.gte(18) & p.title.ne("draft")))
    |> Query::map(split2((_u, p) => sel(p.title)))).to_sql().0,
    content=(
      #|SELECT p."title"
      #|  FROM "users" AS u
      #|  JOIN "posts" AS p ON u."id" = p."author_id"
      #| WHERE u."age" >= ? AND p."title" <> ?
    ),
  )
}

///|
/// A type alias makes the joined shape nameable without changing what the
/// query carries, so a named query can have a readable signature while still
/// carrying a plain tuple.
pub type UserPost = (UserCols, PostCols)

///|
fn joined_users() -> Query[UserPost, String] {
  from(users())
  |> Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
  |> Query::map(split2((_u, p) => sel(p.title)))
}

///|
test "an alias names the joined shape" {
  inspect(
    joined_users().to_sql().0,
    content=(
      #|SELECT p."title"
      #|  FROM "users" AS u
      #|  JOIN "posts" AS p ON u."id" = p."author_id"
    ),
  )
}
