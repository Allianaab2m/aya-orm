///|
/// The table is typed by the domain entity, so a query decodes straight into
/// the sum type without the caller ever seeing `OrderRow`.
test "a row becomes the state it represents" {
  let q = @aya.from(orders())
  let shipped : @aya.Row = [
      @aya.SqlValue::VInt(1),
      @aya.SqlValue::VInt(3),
      @aya.SqlValue::VText("shipped"),
      @aya.SqlValue::VText("2026-08-01"),
      @aya.SqlValue::VText("ZZ123"),
    ][:]
  debug_inspect(
    (q.decode)(shipped),
    content=(
      #|Shipped(id=1, items=3, submitted_at="2026-08-01", tracking="ZZ123")
    ),
  )
  let draft : @aya.Row = [
      @aya.SqlValue::VInt(2),
      @aya.SqlValue::VInt(1),
      @aya.SqlValue::VText("draft"),
      @aya.SqlValue::VNull,
      @aya.SqlValue::VNull,
    ][:]
  debug_inspect(
    (q.decode)(draft),
    content=(
      #|Draft(id=2, items=1)
    ),
  )
}

///|
/// A row the domain type has no state for is rejected at the seam, rather than
/// producing a half-built value.
test "an illegal stored state fails to decode" {
  let q = @aya.from(orders())
  let broken : @aya.Row = [
      @aya.SqlValue::VInt(3),
      @aya.SqlValue::VInt(1),
      @aya.SqlValue::VText("shipped"),
      @aya.SqlValue::VText("2026-08-01"),
      @aya.SqlValue::VNull,
    ][:]
  try {
    let _ = (q.decode)(broken)
    fail("expected Malformed")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|Malformed("orders id=3: status shipped with submitted_at=true tracking=false")
        ),
      )
  }
}

///|
/// Writing goes the other way through the same seam: an insert takes a domain
/// value and the nulls for the absent states are filled in by `to_row`.
test "each state writes the row its shape implies" {
  let (sql, draft) = @aya.insert(orders(), Draft(id=2, items=1)).to_sql()
  inspect(
    sql,
    content=(
      #|INSERT INTO "orders" ("id", "items", "status", "submitted_at", "tracking")
      #| VALUES (?, ?, ?, ?, ?)
    ),
  )
  debug_inspect(
    draft,
    content=(
      #|[VInt(2), VInt(1), VText("draft"), VNull, VNull]
    ),
  )
  let (_, shipped) = @aya.insert(
    orders(),
    Shipped(id=1, items=3, submitted_at="2026-08-01", tracking="ZZ123"),
  ).to_sql()
  debug_inspect(
    shipped,
    content=(
      #|[
      #|  VInt(1),
      #|  VInt(3),
      #|  VText("shipped"),
      #|  VText("2026-08-01"),
      #|  VText("ZZ123"),
      #|]
    ),
  )
}

///|
/// Filters are still written against the row's columns, because that is what
/// the database actually has. The domain type governs what comes back.
test "queries filter on storage columns and return domain values" {
  inspect(
    (@aya.from(orders())
    |> @aya.Query::filter(o => o.status.eq("shipped") & o.tracking.is_some())
    |> @aya.Query::order_by(o => [o.submitted_at.desc()])).to_sql().0,
    content=(
      #|SELECT o."id", o."items", o."status", o."submitted_at", o."tracking"
      #|  FROM "orders" AS o
      #| WHERE o."status" = ? AND o."tracking" IS NOT NULL
      #| ORDER BY o."submitted_at" DESC
    ),
  )
}
