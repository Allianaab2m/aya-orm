///|
/// Each state's table only has the columns that state actually has, so no
/// query has to mention a column that might be NULL.
test "per-state tables select only what the state owns" {
  inspect(
    drafts_as_orders().to_sql().0,
    content=(
      #|SELECT d."id", d."items"
      #|  FROM "order_drafts" AS d
    ),
  )
  inspect(
    shipped_as_orders().to_sql().0,
    content=(
      #|SELECT p."id", p."items", p."submitted_at", p."tracking"
      #|  FROM "order_shipped" AS p
    ),
  )
}

///|
/// Decoding is total: there is no stored row that fails to be an `Order`.
test "rows decode into their state without a failure case" {
  let q = drafts_as_orders()
  let draft : @sql.Row = [@sql.SqlValue::VInt(2), @sql.SqlValue::VInt(1)][:]
  debug_inspect(
    (q.decode)(draft),
    content=(
      #|Draft(id=2, items=1)
    ),
  )
  let s = shipped_as_orders()
  let shipped : @sql.Row = [
      @sql.SqlValue::VInt(1),
      @sql.SqlValue::VInt(3),
      @sql.SqlValue::VText("2026-08-01"),
      @sql.SqlValue::VText("ZZ123"),
    ][:]
  debug_inspect(
    (s.decode)(shipped),
    content=(
      #|Shipped(id=1, items=3, submitted_at="2026-08-01", tracking="ZZ123")
    ),
  )
}

///|
/// A state transition is two statements that have to land together. cairn can
/// build both, but has nothing yet that makes them atomic.
test "a transition is a delete plus an insert" {
  let (remove, add) = submit({ id: 2, items: 1 }, at="2026-08-01")
  inspect(
    remove.0,
    content=(
      #|DELETE FROM "order_drafts" AS d
      #|  WHERE d."id" = ?
    ),
  )
  debug_inspect(
    remove.1,
    content=(
      #|[VInt(2)]
    ),
  )
  inspect(
    add.0,
    content=(
      #|INSERT INTO "order_submitted" ("id", "items", "submitted_at")
      #| VALUES (?, ?, ?)
    ),
  )
  debug_inspect(
    add.1,
    content=(
      #|[VInt(2), VInt(1), VText("2026-08-01")]
    ),
  )
}

///|
/// Reading "an order in any state" is where the per-state schema costs
/// something: there is no UNION in cairn, so it is three separate statements
/// whose results the caller concatenates.
test "reading across states takes one query per state" {
  let parts = [
    drafts_as_orders().to_sql().0,
    submitted_as_orders().to_sql().0,
    shipped_as_orders().to_sql().0,
  ]
  inspect(parts.length(), content="3")
  inspect(
    @sql.join(parts, "\n-- UNION ALL --\n"),
    content=(
      #|SELECT d."id", d."items"
      #|  FROM "order_drafts" AS d
      #|-- UNION ALL --
      #|SELECT s."id", s."items", s."submitted_at"
      #|  FROM "order_submitted" AS s
      #|-- UNION ALL --
      #|SELECT p."id", p."items", p."submitted_at", p."tracking"
      #|  FROM "order_shipped" AS p
    ),
  )
}
