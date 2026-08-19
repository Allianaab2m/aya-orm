///|
/// A newtype column keeps its type all the way through the query builder:
/// `eq` on `Column[AccountId]` only accepts an `AccountId`.
test "domain types survive into the query" {
  let (sql, params) = (@sql.from(Account::table())
  |> @sql.Query::filter(a => a.plan.eq(Pro))
  |> @sql.Query::filter(a => a.id.eq(AccountId(7)))
  |> @sql.Query::map(a => @sql.sel(a.email))).to_sql()
  inspect(
    sql,
    content=(
      #|SELECT a."email"
      #|  FROM "accounts" AS a
      #| WHERE a."plan" = ?
      #|   AND a."id" = ?
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VText("pro"), VInt(7)]
    ),
  )
}

///|
/// The decoder rebuilds the domain types, so nothing downstream sees an `Int`
/// where an `AccountId` belongs.
test "rows decode straight into domain types" {
  let q = @sql.from(Account::table())
  let row : @sql.Row = [
      @sql.SqlValue::VInt(7),
      @sql.SqlValue::VText("a@example.com"),
      @sql.SqlValue::VText("pro"),
    ][:]
  debug_inspect(
    (q.decode)(row),
    content=(
      #|{ id: AccountId(7), email: "a@example.com", plan: Pro }
    ),
  )
}

///|
/// A value outside the domain fails at decode time rather than leaking through
/// as an untyped string.
test "an out-of-domain value is rejected" {
  let q = @sql.from(Account::table())
  let row : @sql.Row = [
      @sql.SqlValue::VInt(7),
      @sql.SqlValue::VText("a@example.com"),
      @sql.SqlValue::VText("enterprise"),
    ][:]
  try {
    let _ = (q.decode)(row)
    fail("expected TypeMismatch")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|TypeMismatch(column="plan", expected="Plan")
        ),
      )
  }
}

///|
/// Writing goes through the same encoders, so an insert stores the encoded
/// form without any hand-written conversion.
test "domain types encode on the way out" {
  let (sql, params) = @sql.insert(Account::table(), Account::{
    id: AccountId(7),
    email: "a@example.com",
    plan: Free,
  }).to_sql()
  inspect(
    sql,
    content=(
      #|INSERT INTO "accounts" ("id", "email", "plan")
      #| VALUES (?, ?, ?)
    ),
  )
  debug_inspect(
    params,
    content=(
      #|[VInt(7), VText("a@example.com"), VText("free")]
    ),
  )
}
