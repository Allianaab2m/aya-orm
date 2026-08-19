///|
/// A driver stub for the example package, so the execution layer can be shown
/// end to end without a real database binding.
struct StubDb {
  log : Array[String]
  /// The statements themselves, first line only, so assertions stay readable.
  stmts : Array[String]
  mut results : Array[Array[Array[@sql.SqlValue]]]
  /// Fail the statement this many operations in, to test rollback.
  mut fail_after : Int?
}

///|
fn StubDb::new(results? : Array[Array[Array[@sql.SqlValue]]] = []) -> StubDb {
  { log: [], stmts: [], results, fail_after: None }
}

///|
impl @sql.Driver for StubDb with fn query(self, _sql, _params) {
  self.log.push("QUERY")
  if self.results.is_empty() {
    []
  } else {
    let head = self.results[0]
    self.results = self.results[1:].to_owned()
    head
  }
}

///|
impl @sql.Driver for StubDb with fn execute(self, _sql, _params) {
  if self.fail_after is Some(n) {
    if n == 0 {
      raise @sql.QueryFailed(sql=_sql, message="simulated failure")
    }
    self.fail_after = Some(n - 1)
  }
  self.log.push("EXEC")
  self.stmts.push(_sql.split("\n").head().unwrap().to_owned())
  1
}

///|
impl @sql.Driver for StubDb with fn dialect(_self) {
  @sql.Dialect::Sqlite
}

///|
impl @sql.Driver for StubDb with fn begin(self) {
  self.log.push("BEGIN")
}

///|
impl @sql.Driver for StubDb with fn commit(self) {
  self.log.push("COMMIT")
}

///|
impl @sql.Driver for StubDb with fn rollback(self) {
  self.log.push("ROLLBACK")
}

///|
/// Running a query over a domain-typed table hands back domain values. The row
/// type never appears.
test "queries return domain entities" {
  let db = StubDb::new(results=[
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
/// A state transition is exactly what a transaction is for: the delete and the
/// insert either both land or neither does.
test "a state transition runs inside one transaction" {
  let db = StubDb::new()
  let moved = @sql.transaction(db, conn => {
    let removed = @sql.delete(DraftRow::table(), d => d.id.eq(2)).run(conn)
    let added = @sql.insert(SubmittedRow::table(), {
      id: 2,
      items: 1,
      submitted_at: "2026-08-01",
    }).run(conn)
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
test "a failed transition rolls the whole transition back" {
  let db = StubDb::new()
  try {
    let _ : Unit = @sql.transaction(db, conn => {
      let _ = @sql.delete(DraftRow::table(), d => d.id.eq(2)).run(conn)
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
