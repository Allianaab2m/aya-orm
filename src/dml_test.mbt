///|
test "insert writes every bound column" {
  let (sql, params) = insert(users(), User::{ id: 1, name: "alice" }).to_sql()
  inspect(
    sql,
    content=(
      #|INSERT INTO "users" ("id", "name")
      #| VALUES (?, ?)
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VInt(1), VText("alice")]
    ),
  )
}

///|
test "insert_many emits one statement" {
  inspect(
    insert_many(users(), [
      User::{ id: 1, name: "alice" },
      User::{ id: 2, name: "bob" },
    ]).to_sql().0,
    content=(
      #|INSERT INTO "users" ("id", "name")
      #| VALUES (?, ?), (?, ?)
    ),
  )
}

///|
test "insert_except omits a generated key" {
  let (sql, params) = insert_except(users(), User::{ id: 0, name: "alice" }, omit=[
    "id",
  ]).to_sql()
  inspect(
    sql,
    content=(
      #|INSERT INTO "users" ("name")
      #| VALUES (?)
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VText("alice")]
    ),
  )
}

///|
test "insert with no rows is rejected" {
  try {
    let _ = insert_many(users(), []).to_sql()
    fail("expected EmptyInsert")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|EmptyInsert(table="users")
        ),
      )
  }
}

///|
test "update sets and filters in textual parameter order" {
  let (sql, params) = (update(users(), u => u.id.eq(7))
  |> Update::set(u => u.name, "bob")).to_sql()
  inspect(
    sql,
    content=(
      #|UPDATE "users" AS u
      #|    SET "name" = ?
      #|  WHERE u."id" = ?
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VText("bob"), VInt(7)]
    ),
  )
}

///|
test "update accumulates filters" {
  inspect(
    (update(users(), u => u.age.gte(18))
    |> Update::set(u => u.name, "bob")
    |> Update::filter(u => u.deleted_at.is_none())).to_sql().0,
    content=(
      #|UPDATE "users" AS u
      #|    SET "name" = ?
      #|  WHERE u."age" >= ?
      #|    AND u."deleted_at" IS NULL
    ),
  )
}

///|
test "update without an assignment is rejected" {
  try {
    let _ = update(users(), u => u.id.eq(7)).to_sql()
    fail("expected EmptyUpdate")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|EmptyUpdate(table="users")
        ),
      )
  }
}

///|
test "update_all is unfiltered" {
  inspect(
    (update_all(users()) |> Update::set(u => u.name, "bob")).to_sql().0,
    content=(
      #|UPDATE "users" AS u
      #|    SET "name" = ?
    ),
  )
}

///|
test "delete requires a predicate" {
  let (sql, params) = delete(users(), u => u.id.eq(7)).to_sql()
  inspect(
    sql,
    content=(
      #|DELETE FROM "users" AS u
      #|  WHERE u."id" = ?
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VInt(7)]
    ),
  )
}

///|
test "delete_all is unfiltered" {
  inspect(
    delete_all(users()).to_sql().0,
    content=(
      #|DELETE FROM "users" AS u
    ),
  )
}
