///|
/// A driver that records what it was asked to run and replays canned results.
///
/// It exercises cairn's own layer — SQL text, parameter order, decoding,
/// transaction bracketing — without pulling in a real database. It is not a
/// SQL engine and does not pretend to be one.
struct FakeDb {
  /// What the driver was asked to do, in order.
  log : Array[String]
  /// The statements themselves, with their bound parameters.
  stmts : Array[(String, Array[SqlValue])]
  /// Result sets returned by successive `query` calls.
  mut results : Array[Array[Array[SqlValue]]]
  /// Row counts returned by successive `execute` calls.
  mut counts : Array[Int]
  /// When set, the next statement of any kind fails with this message.
  mut fail_next : String?
}

///|
fn FakeDb::new(
  results? : Array[Array[Array[SqlValue]]] = [],
  counts? : Array[Int] = [],
) -> FakeDb {
  { log: [], stmts: [], results, counts, fail_next: None }
}

///|
/// Consume a pending failure, if one was armed.
fn FakeDb::check(self : FakeDb, sql : String) -> Unit raise DbError {
  if self.fail_next is Some(msg) {
    self.fail_next = None
    raise QueryFailed(sql~, message=msg)
  }
}

///|
impl Driver for FakeDb with fn query(self, sql, params) {
  self.check(sql)
  self.log.push("QUERY")
  self.stmts.push((one_line(sql), params))
  if self.results.is_empty() {
    []
  } else {
    let head = self.results[0]
    self.results = self.results[1:].to_owned()
    head
  }
}

///|
impl Driver for FakeDb with fn execute(self, sql, params) {
  self.check(sql)
  self.log.push("EXEC")
  self.stmts.push((one_line(sql), params))
  if self.counts.is_empty() {
    0
  } else {
    let head = self.counts[0]
    self.counts = self.counts[1:].to_owned()
    head
  }
}

///|
impl Driver for FakeDb with fn dialect(_self) {
  Dialect::Sqlite
}

///|
impl Driver for FakeDb with fn begin(self) {
  self.log.push("BEGIN")
}

///|
impl Driver for FakeDb with fn commit(self) {
  self.log.push("COMMIT")
}

///|
impl Driver for FakeDb with fn rollback(self) {
  self.log.push("ROLLBACK")
}

///|
/// Collapse a statement onto one line so the log stays readable.
fn one_line(sql : String) -> String {
  join(sql.split("\n").map(s => s.trim().to_owned()).to_array(), " ")
}

///|
test "a query runs, decodes and returns every row" {
  let db = FakeDb::new(results=[
    [[VInt(1), VText("alice")], [VInt(2), VText("bob")]],
  ])
  let rows = (from(users()) |> Query::map(u => sel2(u.id, u.name))).run(db)
  debug_inspect(
    rows,
    content=(
      #|[(1, "alice"), (2, "bob")]
    ),
  )
  debug_inspect(
    db.stmts,
    content=(
      #|[("SELECT u.\"id\", u.\"name\" FROM \"users\" AS u", [])]
    ),
  )
}

///|
test "one requires exactly one row" {
  let q = from(users())
    |> Query::filter(u => u.id.eq(1))
    |> Query::map(u => sel(u.name))
  debug_inspect(
    q.one(FakeDb::new(results=[[[VText("alice")]]])),
    content=(
      #|"alice"
    ),
  )
  try {
    let _ = q.one(FakeDb::new(results=[[]]))
    fail("expected NotFound")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|NotFound(sql="SELECT u.\"name\"\n  FROM \"users\" AS u\n WHERE u.\"id\" = ?")
        ),
      )
  }
  try {
    let _ = q.one(FakeDb::new(results=[[[VText("a")], [VText("b")]]]))
    fail("expected TooManyRows")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|TooManyRows(
          #|  sql="SELECT u.\"name\"\n  FROM \"users\" AS u\n WHERE u.\"id\" = ?",
          #|  got=2,
          #|)
        ),
      )
  }
}

///|
test "first tolerates an empty result" {
  let q = from(users()) |> Query::map(u => sel(u.name))
  debug_inspect(q.first(FakeDb::new(results=[[]])), content="None")
  debug_inspect(
    q.first(FakeDb::new(results=[[[VText("alice")]]])),
    content=(
      #|Some("alice")
    ),
  )
}

///|
test "dml returns the affected row count" {
  let db = FakeDb::new(counts=[1, 3])
  inspect(insert(users(), User::{ id: 1, name: "alice" }).run(db), content="1")
  inspect(delete(users(), u => u.age.lt(18)).run(db), content="3")
  debug_inspect(
    db.stmts,
    content=(
      #|[
      #|  (
      #|    "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?, ?)",
      #|    [VInt(1), VText("alice")],
      #|  ),
      #|  ("DELETE FROM \"users\" AS u WHERE u.\"age\" < ?", [VInt(18)]),
      #|]
    ),
  )
}

///|
test "a transaction commits when the body returns" {
  let db = FakeDb::new(counts=[1, 1])
  let moved = transaction(db, conn => {
    let removed = delete(users(), u => u.id.eq(2)).run(conn)
    let added = insert(users(), User::{ id: 2, name: "bob" }).run(conn)
    removed + added
  })
  inspect(moved, content="2")
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "EXEC", "EXEC", "COMMIT"]
    ),
  )
}

///|
test "a transaction rolls back and re-raises when the body fails" {
  let db = FakeDb::new(counts=[1])
  try {
    let _ : Unit = transaction(db, conn => {
      let _ = delete(users(), u => u.id.eq(2)).run(conn)
      // Something the caller decides is fatal, half way through.
      raise DecodeError::Malformed("business rule violated")
    })
    fail("expected the body's error to propagate")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|Malformed("business rule violated")
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

///|
test "a driver failure inside a transaction also rolls back" {
  let db = FakeDb::new(counts=[1])
  db.fail_next = Some("disk full")
  try {
    let _ : Int = transaction(db, conn => {
      insert(users(), User::{ id: 1, name: "alice" }).run(conn)
    })
    fail("expected the driver error to propagate")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|QueryFailed(
          #|  sql="INSERT INTO \"users\" (\"id\", \"name\")\n VALUES (?, ?)",
          #|  message="disk full",
          #|)
        ),
      )
  }
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "ROLLBACK"]
    ),
  )
}

///|
/// If BEGIN itself fails there is no transaction to undo, so no ROLLBACK is
/// sent. Pinning this keeps a later refactor from "helpfully" adding one.
test "a failed begin does not roll back" {
  let db = FailingBegin::{ log: [] }
  try {
    let _ : Int = transaction(db, conn => {
      insert(users(), User::{ id: 1, name: "alice" }).run(conn)
    })
    fail("expected the begin error to propagate")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|ConnectionFailed("no connection")
        ),
      )
  }
  debug_inspect(
    db.log,
    content=(
      #|[]
    ),
  )
}

///|
struct FailingBegin {
  log : Array[String]
}

///|
impl Driver for FailingBegin with fn query(_self, _sql, _params) {
  []
}

///|
impl Driver for FailingBegin with fn execute(self, _sql, _params) {
  self.log.push("EXEC")
  0
}

///|
impl Driver for FailingBegin with fn dialect(_self) {
  Dialect::Sqlite
}

///|
impl Driver for FailingBegin with fn begin(_self) {
  raise ConnectionFailed("no connection")
}

///|
impl Driver for FailingBegin with fn commit(self) {
  self.log.push("COMMIT")
}

///|
impl Driver for FailingBegin with fn rollback(self) {
  self.log.push("ROLLBACK")
}
