///|
/// The generated `User::table()` is a plain `@aya.Table`, so the whole query
/// pipeline works against it without any hand-written column plumbing.
test "query through a generated table" {
  inspect(
    (@aya.from(User::table())
    |> @aya.Query::filter(u => u.age.gte(18) & u.deleted_at.is_none())
    |> @aya.Query::map(u => @aya.sel(u.name))
    |> @aya.Query::order_by(u => [u.name.asc()])
    |> @aya.Query::limit(20)).to_sql().0,
    content=(
      #|SELECT u."name"
      #|  FROM "users" AS u
      #| WHERE u."age" >= ? AND u."deleted_at" IS NULL
      #| ORDER BY u."name" ASC
      #| LIMIT ?
    ),
  )
}

///|
/// The generated projection and decoder come from one field list, so a full
/// row round-trips back into the entity.
test "generated decoder round-trips a row" {
  let q = @aya.from(User::table())
  let row : @aya.Row = [
      @aya.SqlValue::VInt(7),
      @aya.SqlValue::VText("alice"),
      @aya.SqlValue::VInt(30),
      @aya.SqlValue::VNull,
    ][:]
  debug_inspect(
    (q.decode)(row),
    content=(
      #|{ id: 7, name: "alice", age: 30, deleted_at: None }
    ),
  )
}

///|
/// The generated binding covers the write side, so DML works on the same
/// table value the query pipeline uses.
test "insert through a generated table" {
  let (sql, params) = @aya.insert(User::table(), User::{
    id: 1,
    name: "alice",
    age: 30,
    deleted_at: None,
  }).to_sql()
  inspect(
    sql,
    content=(
      #|INSERT INTO "users" ("id", "name", "age", "deleted_at")
      #| VALUES (?, ?, ?, ?)
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VInt(1), VText("alice"), VInt(30), VNull]
    ),
  )
}

///|
test "insert_except lets the database assign the key" {
  inspect(
    @aya.insert_except(
      User::table(),
      User::{ id: 0, name: "alice", age: 30, deleted_at: None },
      omit=["id"],
    ).to_sql().0,
    content=(
      #|INSERT INTO "users" ("name", "age", "deleted_at")
      #| VALUES (?, ?, ?)
    ),
  )
}

///|
test "update and delete through a generated table" {
  inspect(
    (@aya.update(User::table(), u => u.id.eq(7))
    |> @aya.Update::set(u => u.name, "bob")).to_sql().0,
    content=(
      #|UPDATE "users" AS u
      #|    SET "name" = ?
      #|  WHERE u."id" = ?
    ),
  )
  inspect(
    @aya.delete(User::table(), u => u.age.lt(18)).to_sql().0,
    content=(
      #|DELETE FROM "users" AS u
      #|  WHERE u."age" < ?
    ),
  )
}
