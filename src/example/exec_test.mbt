// The execution layer end to end, against the fake connection rather than a
// database binding. Nothing here is example-specific except the table:
// `@fake.FakeDb` is the same thing a consumer of aya would test against.

///|
/// Running a query over a domain-typed table hands back domain values. The row
/// type never appears.
async test "queries return domain entities" {
  let db = @fake.FakeDb::new(results=[
    [
      [
        @sql.SqlValue::VInt(1),
        @sql.SqlValue::VInt(3),
        @sql.SqlValue::VText("shipped"),
        @sql.SqlValue::VText("2026-08-01"),
        @sql.SqlValue::VText("ZZ123"),
      ],
      [
        @sql.SqlValue::VInt(2),
        @sql.SqlValue::VInt(1),
        @sql.SqlValue::VText("draft"),
        @sql.SqlValue::VNull,
        @sql.SqlValue::VNull,
      ],
    ],
  ])
  debug_inspect(
    @sql.from(orders()).run(db),
    content=(
      #|[
      #|  Shipped(id=1, items=3, submitted_at="2026-08-01", tracking="ZZ123"),
      #|  Draft(id=2, items=1),
      #|]
    ),
  )
}

///|
/// Writes go through the same domain-typed table, so an `Order` is inserted
/// without any hand-written flattening at the call site.
async test "a state transition runs inside one transaction" {
  let db = @fake.FakeDb::new(counts=[1, 1])
  let moved = @sql.transaction(@sql.Tx::new(db), conn => {
    let removed = @sql.delete(orders(), o => o.id.eq(2)).run(conn)
    let added = @sql.insert(
      orders(),
      Submitted(id=2, items=1, submitted_at="2026-08-01"),
    ).run(conn)
    (removed, added)
  })
  debug_inspect(
    moved,
    content=(
      #|(1, 1)
    ),
  )
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "EXEC", "EXEC", "COMMIT"]
    ),
  )
}

///|
/// A failure part way through leaves nothing behind.
async test "a failed transition rolls the whole transition back" {
  let db = @fake.FakeDb::new(counts=[1])
  try {
    let _ : Unit = @sql.transaction(@sql.Tx::new(db), conn => {
      let _ = @sql.delete(orders(), o => o.id.eq(2)).run(conn)
      raise @sql.Malformed("order 2 is not submittable")
    })
    fail("expected the error to propagate")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|Malformed("order 2 is not submittable")
        ),
      )
  }
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "EXEC", "ROLLBACK"]
    ),
  )
}
