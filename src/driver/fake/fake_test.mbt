///|
/// The execution layer's own test fixture: a table small enough to read, with
/// one nullable column so `IS NULL` has something to bind against.
struct UserCols {
  id : @sql.Column[Int]
  name : @sql.Column[String]
  age : @sql.Column[Int]
}

///|
struct User {
  id : Int
  name : String
} derive(Debug, Eq)

///|
fn users() -> @sql.Table[UserCols, User] {
  let cols : UserCols = {
    id: @sql.Column::new(tbl="u", name="id"),
    name: @sql.Column::new(tbl="u", name="name"),
    age: @sql.Column::new(tbl="u", name="age"),
  }
  @sql.Table::new(
    table_name="users",
    tbl="u",
    cols~,
    all=@sql.sel2(cols.id, cols.name).into2((id, name) => User::{ id, name }),
    write=@sql.Binding::new(["id", "name"], u => {
      [@sql.SqlEncode::to_sql_value(u.id), @sql.SqlEncode::to_sql_value(u.name)]
    }),
  )
}

///|
async test "a query runs, decodes and returns every row" {
  let db = FakeDb::new(results=[
    [[@sql.VInt(1), @sql.VText("alice")], [@sql.VInt(2), @sql.VText("bob")]],
  ])
  let rows = (@sql.from(users())
  |> @sql.Query::map(u => @sql.sel2(u.id, u.name))).run(db)
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
  let q = @sql.from(users())
    |> @sql.Query::filter(u => u.id.eq(1))
    |> @sql.Query::map(u => @sql.sel(u.name))
  debug_inspect(
    q.one(FakeDb::new(results=[[[@sql.VText("alice")]]])),
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
    let _ = q.one(FakeDb::new(results=[[[@sql.VText("a")], [@sql.VText("b")]]]))
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
  let q = @sql.from(users()) |> @sql.Query::map(u => @sql.sel(u.name))
  debug_inspect(q.first(FakeDb::new(results=[[]])), content="None")
  debug_inspect(
    q.first(FakeDb::new(results=[[[@sql.VText("alice")]]])),
    content=(
      #|Some("alice")
    ),
  )
}

///|
async test "dml returns the affected row count" {
  let db = FakeDb::new(counts=[1, 3])
  inspect(
    @sql.insert(users(), User::{ id: 1, name: "alice" }).run(db),
    content="1",
  )
  inspect(@sql.delete(users(), u => u.age.lt(18)).run(db), content="3")
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
    @sql.insert(users(), User::{ id: 1, name: "alice" }).run(db),
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
  let moved = @sql.transaction(@sql.Tx::new(db), conn => {
    let removed = @sql.delete(users(), u => u.id.eq(2)).run(conn)
    let added = @sql.insert(users(), User::{ id: 2, name: "bob" }).run(conn)
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
    let _ : Unit = @sql.transaction(@sql.Tx::new(db), conn => {
      let _ = @sql.delete(users(), u => u.id.eq(2)).run(conn)
      // Something the caller decides is fatal, half way through.
      raise @sql.DecodeError::Malformed("business rule violated")
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
    let _ : Int = @sql.transaction(@sql.Tx::new(db), conn => {
      @sql.insert(users(), User::{ id: 1, name: "alice" }).run(conn)
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
  let tx = @sql.Tx::new(db)
  @sql.transaction(tx, _ => {
    // Each of these stands for a repository method that brackets its own work.
    @sql.transaction(tx, conn => {
      @sql.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
    })
    @sql.transaction(tx, conn => {
      @sql.insert(users(), User::{ id: 2, name: "bob" }).run(conn) |> ignore
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
  let tx = @sql.Tx::new(db)
  @sql.transaction(tx, conn => {
    @sql.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
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
  let tx = @sql.Tx::new(db)
  try {
    let _ : Unit = @sql.transaction(tx, _ => {
      @sql.transaction(tx, conn => {
        @sql.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
      })
      @sql.transaction(tx, _ => raise @sql.DecodeError::Malformed("bad row"))
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
  let tx = @sql.Tx::new(db)
  try {
    let _ : Unit = @sql.transaction(tx, conn => {
      @sql.insert(users(), User::{ id: 1, name: "alice" }).run(conn) |> ignore
      @sql.transaction(tx, _ => raise @sql.DecodeError::Malformed("bad row")) catch {
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
  @sql.transaction(tx, conn => {
    @sql.insert(users(), User::{ id: 2, name: "bob" }).run(conn) |> ignore
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
    let _ : Int = @sql.transaction(@sql.Tx::new(db), conn => {
      @sql.insert(users(), User::{ id: 1, name: "alice" }).run(conn)
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
impl @sql.Executor for FailingBegin with fn query(
  _self,
  _sql,
  _params,
  columns~,
) {
  ignore(columns)
  []
}

///|
impl @sql.Executor for FailingBegin with fn execute(self, _sql, _params) {
  self.log.push("EXEC")
  0
}

///|
impl @sql.Executor for FailingBegin with fn dialect(_self) {
  @sql.Dialect::Sqlite
}

///|
impl @sql.Driver for FailingBegin with fn begin(_self) {
  raise @sql.ConnectionFailed("no connection")
}

///|
impl @sql.Driver for FailingBegin with fn commit(self) {
  self.log.push("COMMIT")
}

///|
impl @sql.Driver for FailingBegin with fn rollback(self) {
  self.log.push("ROLLBACK")
}

///|
/// A whole-table summary is exactly one row, so `one` is the natural way to
/// run it. A grouped query is many rows, so `run` is.
async test "summaries run through the execution layer" {
  let total = (@sql.from(users()) |> @sql.Query::reduce(_ => @sql.count())).one(
    FakeDb::new(results=[[[@sql.VInt(7)]]]),
  )
  inspect(total, content="7")
  let per_name = (@sql.from(users())
  |> @sql.Query::group_by(u => u.name, _ => @sql.count())).run(
    FakeDb::new(results=[
      [[@sql.VText("alice"), @sql.VInt(2)], [@sql.VText("bob"), @sql.VInt(1)]],
    ]),
  )
  debug_inspect(
    per_name,
    content=(
      #|[("alice", 2), ("bob", 1)]
    ),
  )
}
