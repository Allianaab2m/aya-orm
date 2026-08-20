///|
/// The execution layer's own test fixture: a table small enough to read, with
/// one nullable column so `IS NULL` has something to bind against.
struct UserCols {
  id : @aya.Column[Int]
  name : @aya.Column[String]
  age : @aya.Column[Int]
}

///|
struct User {
  id : Int
  name : String
} derive(Debug, Eq)

///|
fn users() -> @aya.Table[UserCols, User] {
  let cols : UserCols = {
    id: @aya.Column::new(tbl="u", name="id"),
    name: @aya.Column::new(tbl="u", name="name"),
    age: @aya.Column::new(tbl="u", name="age"),
  }
  @aya.Table::new(
    table_name="users",
    tbl="u",
    cols~,
    all=@aya.sel2(cols.id, cols.name).into2((id, name) => User::{ id, name }),
    write=@aya.Binding::new(["id", "name"], u => {
      [@aya.SqlEncode::to_sql_value(u.id), @aya.SqlEncode::to_sql_value(u.name)]
    }),
  )
}

///|
async test "a query runs, decodes and returns every row" {
  let db = FakeDb::new(results=[
    [[@aya.VInt(1), @aya.VText("alice")], [@aya.VInt(2), @aya.VText("bob")]],
  ])
  let rows = (@aya.from(users())
  |> @aya.Query::map(u => @aya.sel2(u.id, u.name))).run(db)
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
async test "one requires exactly one row" {
  let q = @aya.from(users())
    |> @aya.Query::filter(u => u.id.eq(1))
    |> @aya.Query::map(u => @aya.sel(u.name))
  debug_inspect(
    q.one(FakeDb::new(results=[[[@aya.VText("alice")]]])),
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
    let _ = q.one(FakeDb::new(results=[[[@aya.VText("a")], [@aya.VText("b")]]]))
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
async test "first tolerates an empty result" {
  let q = @aya.from(users()) |> @aya.Query::map(u => @aya.sel(u.name))
  debug_inspect(q.first(FakeDb::new(results=[[]])), content="None")
  debug_inspect(
    q.first(FakeDb::new(results=[[[@aya.VText("alice")]]])),
    content=(
      #|Some("alice")
    ),
  )
}

///|
async test "dml returns the affected row count" {
  let db = FakeDb::new(counts=[1, 3])
  inspect(
    @aya.insert(users(), User::{ id: 1, name: "alice" }).run(db),
    content="1",
  )
  inspect(@aya.delete(users(), u => u.age.lt(18)).run(db), content="3")
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
/// The dialect is the driver's to declare, and it is what decides the
/// placeholder syntax, so the same statement built against a Postgres fake
/// comes out numbered.
async test "the driver's dialect picks the placeholder syntax" {
  let db = FakeDb::new(counts=[1], dialect=Postgres)
  inspect(
    @aya.insert(users(), User::{ id: 1, name: "alice" }).run(db),
    content="1",
  )
  debug_inspect(
    db.stmts,
    content=(
      #|[
      #|  (
      #|    "INSERT INTO \"users\" (\"id\", \"name\") VALUES ($1, $2)",
      #|    [VInt(1), VText("alice")],
      #|  ),
      #|]
    ),
  )
}

///|
async test "a transaction commits when the body returns" {
  let db = FakeDb::new(counts=[1, 1])
  let moved = @aya.transaction(@aya.Tx::new(db), conn => {
    let removed = @aya.delete(users(), u => u.id.eq(2)).run(conn)
    let added = @aya.insert(users(), User::{ id: 2, name: "bob" }).run(conn)
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
async test "a transaction rolls back and re-raises when the body fails" {
  let db = FakeDb::new(counts=[1])
  try {
    let _ : Unit = @aya.transaction(@aya.Tx::new(db), conn => {
      let _ = @aya.delete(users(), u => u.id.eq(2)).run(conn)
      // Something the caller decides is fatal, half way through.
      raise @aya.DecodeError::Malformed("business rule violated")
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
async test "a driver failure inside a transaction also rolls back" {
  let db = FakeDb::new(counts=[1])
  db.fail("disk full")
  try {
    let _ : Int = @aya.transaction(@aya.Tx::new(db), conn => {
      @aya.insert(users(), User::{ id: 1, name: "alice" }).run(conn)
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
/// The point of `Tx`: an inner scope joins the transaction that is already
/// open instead of asking the database to `BEGIN` twice. Two writes that each
/// insist on being atomic end up in one transaction when something wraps them.
async test "a nested transaction joins the enclosing one" {
  let db = FakeDb::new(counts=[1, 1])
  let tx = @aya.Tx::new(db)
  @aya.transaction(tx, _ => {
    // Each of these stands for a repository method that brackets its own work.
    @aya.transaction(tx, conn => {
      @aya.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
    })
    @aya.transaction(tx, conn => {
      @aya.insert(users(), User::{ id: 2, name: "bob" }).run(conn) |> ignore
    })
  })
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "EXEC", "EXEC", "COMMIT"]
    ),
  )
}

///|
/// Run on its own, the very same scope is the outermost one and brackets
/// itself. A repository does not have to know which case it is in.
async test "an unnested transaction brackets itself" {
  let db = FakeDb::new(counts=[1])
  let tx = @aya.Tx::new(db)
  @aya.transaction(tx, conn => {
    @aya.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
  })
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "EXEC", "COMMIT"]
    ),
  )
  // And the `Tx` is back where it started, ready for the next one.
  inspect(tx.is_open(), content="false")
}

///|
/// A failure inside a nested scope propagates like any other, and the
/// outermost scope is still the only one that rolls back.
async test "a nested failure rolls the whole transaction back once" {
  let db = FakeDb::new(counts=[1])
  let tx = @aya.Tx::new(db)
  try {
    let _ : Unit = @aya.transaction(tx, _ => {
      @aya.transaction(tx, conn => {
        @aya.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
      })
      @aya.transaction(tx, _ => raise @aya.DecodeError::Malformed("bad row"))
    })
    fail("expected the nested failure to propagate")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|Malformed("bad row")
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
/// Catching a nested scope's failure does not rescue it. Without a savepoint
/// there is no way to undo only that scope's writes, so the transaction is
/// rollback-only from then on and the outermost scope refuses to commit —
/// reporting the failure that made it impossible rather than the swallowing.
async test "swallowing a nested failure still forbids the commit" {
  let db = FakeDb::new(counts=[1])
  let tx = @aya.Tx::new(db)
  try {
    let _ : Unit = @aya.transaction(tx, conn => {
      @aya.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
      @aya.transaction(tx, _ => raise @aya.DecodeError::Malformed("bad row")) catch {
        // "It is fine, carry on" — which it is not.
        _ => ()
      }
    })
    fail("expected the commit to be refused")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|RollbackOnly(cause=Malformed("bad row"))
        ),
      )
  }
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "EXEC", "ROLLBACK"]
    ),
  )
  // The poison is scoped to the transaction that was poisoned, not to the
  // connection: the next transaction starts clean.
  @aya.transaction(tx, conn => {
    @aya.insert(users(), User::{ id: 2, name: "bob" }).run(conn) |> ignore
  })
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "EXEC", "ROLLBACK", "BEGIN", "EXEC", "COMMIT"]
    ),
  )
}

///|
/// If BEGIN itself fails there is no transaction to undo, so no ROLLBACK is
/// sent. Pinning this keeps a later refactor from "helpfully" adding one.
async test "a failed begin does not roll back" {
  let db = FailingBegin::{ log: [] }
  try {
    let _ : Int = @aya.transaction(@aya.Tx::new(db), conn => {
      @aya.insert(users(), User::{ id: 1, name: "alice" }).run(conn)
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
impl @aya.Executor for FailingBegin with fn query(
  _self,
  _sql,
  _params,
  columns~,
) {
  ignore(columns)
  []
}

///|
impl @aya.Executor for FailingBegin with fn execute(self, _sql, _params) {
  self.log.push("EXEC")
  0
}

///|
impl @aya.Executor for FailingBegin with fn dialect(_self) {
  @aya.Dialect::Sqlite
}

///|
impl @aya.Driver for FailingBegin with fn begin(_self) {
  raise @aya.ConnectionFailed("no connection")
}

///|
impl @aya.Driver for FailingBegin with fn commit(self) {
  self.log.push("COMMIT")
}

///|
impl @aya.Driver for FailingBegin with fn rollback(self) {
  self.log.push("ROLLBACK")
}

///|
/// A whole-table summary is exactly one row, so `one` is the natural way to
/// run it. A grouped query is many rows, so `run` is.
async test "summaries run through the execution layer" {
  let total = (@aya.from(users()) |> @aya.Query::reduce(_ => @aya.count())).one(
    FakeDb::new(results=[[[@aya.VInt(7)]]]),
  )
  inspect(total, content="7")
  let per_name = (@aya.from(users())
  |> @aya.Query::group_by(u => u.name, _ => @aya.count())).run(
    FakeDb::new(results=[
      [[@aya.VText("alice"), @aya.VInt(2)], [@aya.VText("bob"), @aya.VInt(1)]],
    ]),
  )
  debug_inspect(
    per_name,
    content=(
      #|[("alice", 2), ("bob", 1)]
    ),
  )
}
