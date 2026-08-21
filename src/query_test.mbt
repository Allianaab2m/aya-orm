///|
struct UserCols {
  id : Column[Int]
  name : Column[String]
  age : Column[Int]
  deleted_at : Column[String?]
}

///|
struct User {
  id : Int
  name : String
} derive(Debug, Eq)

///|
fn users() -> Table[UserCols, User] {
  let cols : UserCols = {
    id: Column::new(tbl="u", name="id"),
    name: Column::new(tbl="u", name="name"),
    age: Column::new(tbl="u", name="age"),
    deleted_at: Column::new(tbl="u", name="deleted_at"),
  }
  Table::new(
    table_name="users",
    tbl="u",
    cols~,
    all=sel2(cols.id, cols.name).into2((id, name) => User::{ id, name }),
    write=Binding::new(["id", "name"], u => {
      [SqlEncode::to_sql_value(u.id), SqlEncode::to_sql_value(u.name)]
    }),
  )
}

///|
test "select all columns" {
  inspect(
    from(users()).to_sql().0,
    content=(
      #|SELECT u."id", u."name"
      #|  FROM "users" AS u
    ),
  )
}

///|
test "filter and project" {
  inspect(
    (from(users())
    |> Query::filter(u => u.age.gte(18) & u.deleted_at.is_none())
    |> Query::map(u => sel2(u.id, u.name))).to_sql().0,
    content=(
      #|SELECT u."id", u."name"
      #|  FROM "users" AS u
      #| WHERE u."age" >= ? AND u."deleted_at" IS NULL
    ),
  )
}

///|
test "order and limit" {
  inspect(
    (from(users())
    |> Query::filter(u => u.age.gte(18))
    |> Query::map(u => sel(u.name))
    |> Query::order_by(u => [u.name.asc(), u.id.desc()])
    |> Query::limit(20)).to_sql().0,
    content=(
      #|SELECT u."name"
      #|  FROM "users" AS u
      #| WHERE u."age" >= ?
      #| ORDER BY u."name" ASC, u."id" DESC
      #| LIMIT ?
    ),
  )
}

///|
test "multiple filters are ANDed" {
  inspect(
    (from(users())
    |> Query::filter(u => u.age.gte(18))
    |> Query::filter(u => u.name.ne("admin"))
    |> Query::map(u => sel(u.id))).to_sql().0,
    content=(
      #|SELECT u."id"
      #|  FROM "users" AS u
      #| WHERE u."age" >= ?
      #|   AND u."name" <> ?
    ),
  )
}

///|
test "params follow textual order" {
  let (_, params) = (from(users())
  |> Query::filter(u => u.age.gte(18))
  |> Query::map(u => sel(u.name))
  |> Query::limit(20)).to_sql()
  debug_inspect(params, content="[VInt(18), VInt(20)]")
}

///|
test "decoder follows the projection" {
  let q = from(users()) |> Query::map(u => sel2(u.id, u.name))
  let row : Row = [SqlValue::VInt(7), SqlValue::VText("alice")][:]
  debug_inspect(
    (q.decode)(row),
    content=(
      #|(7, "alice")
    ),
  )
}

///|
test "into2 lifts a tuple into a struct" {
  let q = from(users())
    |> Query::map(u => {
      sel2(u.id, u.name).into2((id, name) => User::{ id, name })
    })
  let row : Row = [SqlValue::VInt(7), SqlValue::VText("alice")][:]
  debug_inspect(
    (q.decode)(row),
    content=(
      #|{ id: 7, name: "alice" }
    ),
  )
}
