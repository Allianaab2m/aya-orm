///|
/// The wrapper is opaque: its representation cannot be taken apart from
/// outside the package, so the only ways to reach the outer-joined table are
/// `col` (nullable column) and `row` (optional row).
test "the nullable side is only reachable through its accessors" {
  let q = @sql.from(User::table())
    |> @sql.Query::left_join(OrderRow::table(), (u, o) => u.id.eq_col(o.id))
    |> @sql.Query::map(c => @sql.sel2(c.0.name, c.1.col(o => o.status)))
  inspect(
    q.to_sql().0,
    content=(
      #|SELECT u."name", o."status"
      #|  FROM "users" AS u
      #|  LEFT JOIN "orders" AS o ON u."id" = o."id"
    ),
  )
}

///|
/// The type is still nameable from outside, which it has to be: it appears in
/// the type of any query that has been left-joined.
pub fn joined() -> @sql.Query[
  (UserCols, @sql.Nullable[OrderCols, OrderRow]),
  User,
] {
  @sql.from(User::table())
  |> @sql.Query::left_join(OrderRow::table(), (u, o) => u.id.eq_col(o.id))
}
