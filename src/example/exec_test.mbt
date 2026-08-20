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
        @aya.SqlValue::VInt(1),
        @aya.SqlValue::VInt(3),
        @aya.SqlValue::VText("shipped"),
        @aya.SqlValue::VText("2026-08-01"),
        @aya.SqlValue::VText("ZZ123"),
      ],
      [
        @aya.SqlValue::VInt(2),
        @aya.SqlValue::VInt(1),
        @aya.SqlValue::VText("draft"),
        @aya.SqlValue::VNull,
        @aya.SqlValue::VNull,
      ],
    ],
  ])
  debug_inspect(
    @aya.from(orders()).run(db),
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
  let moved = @aya.transaction(@aya.Tx::new(db), conn => {
    let removed = @aya.delete(orders(), o => o.id.eq(2)).run(conn)
    let added = @aya.insert(
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
    let _ : Unit = @aya.transaction(@aya.Tx::new(db), conn => {
      let _ = @aya.delete(orders(), o => o.id.eq(2)).run(conn)
      raise @aya.Malformed("order 2 is not submittable")
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
