///|
/// Loading the aggregate is a single statement, whatever phase it is in.
async test "one query loads the whole aggregate" {
  let repo = SqlTickets::new(@sql.Tx::new(@fake.FakeDb::new()))
  let _ = TicketRepository::find(repo, 1)
  inspect(
    (ticket_query() |> @sql.Query::filter(j => j.ticket.id.eq(1))).to_sql().0,
    content=(
      #|SELECT t."id", t."subject", ta."ticket_id", ta."assignee", tc."ticket_id", tc."resolution"
      #|  FROM "tickets" AS t
      #|  LEFT JOIN "ticket_assignments" AS ta ON t."id" = ta."ticket_id"
      #|  LEFT JOIN "ticket_closures" AS tc ON t."id" = tc."ticket_id"
      #| WHERE t."id" = ?
    ),
  )
}

///|
/// Which phase rows came back is the state. No discriminator column exists.
test "the phases present determine the state" {
  let q = ticket_query()
  let open : @sql.Row = [
      @sql.SqlValue::VInt(1),
      @sql.SqlValue::VText("printer on fire"),
      @sql.SqlValue::VNull,
      @sql.SqlValue::VNull,
      @sql.SqlValue::VNull,
      @sql.SqlValue::VNull,
    ][:]
  debug_inspect(
    (q.decode)(open),
    content=(
      #|Open(id=1, subject="printer on fire")
    ),
  )
  let assigned : @sql.Row = [
      @sql.SqlValue::VInt(1),
      @sql.SqlValue::VText("printer on fire"),
      @sql.SqlValue::VInt(1),
      @sql.SqlValue::VText("dana"),
      @sql.SqlValue::VNull,
      @sql.SqlValue::VNull,
    ][:]
  debug_inspect(
    (q.decode)(assigned),
    content=(
      #|Assigned(id=1, subject="printer on fire", assignee="dana")
    ),
  )
  let closed : @sql.Row = [
      @sql.SqlValue::VInt(1),
      @sql.SqlValue::VText("printer on fire"),
      @sql.SqlValue::VInt(1),
      @sql.SqlValue::VText("dana"),
      @sql.SqlValue::VInt(1),
      @sql.SqlValue::VText("unplugged it"),
    ][:]
  debug_inspect(
    (q.decode)(closed),
    content=(
      #|Closed(
      #|  id=1,
      #|  subject="printer on fire",
      #|  assignee="dana",
      #|  resolution="unplugged it",
      #|)
    ),
  )
}

///|
/// A domain-meaningful query, expressed as absence of a phase row.
test "unassigned is the absence of an assignment row" {
  inspect(
    (ticket_query()
    |> @sql.Query::filter(j => j.assignment.col(a => a.ticket_id).is_none())).to_sql().0,
    content=(
      #|SELECT t."id", t."subject", ta."ticket_id", ta."assignee", tc."ticket_id", tc."resolution"
      #|  FROM "tickets" AS t
      #|  LEFT JOIN "ticket_assignments" AS ta ON t."id" = ta."ticket_id"
      #|  LEFT JOIN "ticket_closures" AS tc ON t."id" = tc."ticket_id"
      #| WHERE ta."ticket_id" IS NULL
    ),
  )
}

///|
/// Saving a brand new ticket writes only the base row.
async test "saving an open ticket inserts one row" {
  let db = @fake.FakeDb::new(results=[[]])
  let repo = SqlTickets::new(@sql.Tx::new(db))
  TicketRepository::save(repo, Open(id=1, subject="printer on fire"))
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "QUERY", "EXEC", "COMMIT"]
    ),
  )
  // The lookup that `save` starts with is statement 0; what it decided to
  // write is the rest.
  debug_inspect(
    db.stmts[1:],
    content=(
      #|<ArrayView:
      #|  [
      #|    (
      #|      "INSERT INTO \"tickets\" (\"id\", \"subject\") VALUES (?, ?)",
      #|      [VInt(1), VText("printer on fire")],
      #|    ),
      #|  ]>
    ),
  )
}

///|
/// Saving a ticket that has moved on inserts only the phase rows that are
/// missing: the base row is already there, so it is left alone.
async test "saving a transition inserts only what is new" {
  // The find inside `save` reports an already-open ticket.
  let db = @fake.FakeDb::new(results=[
    [
      [
        @sql.SqlValue::VInt(1),
        @sql.SqlValue::VText("printer on fire"),
        @sql.SqlValue::VNull,
        @sql.SqlValue::VNull,
        @sql.SqlValue::VNull,
        @sql.SqlValue::VNull,
      ],
    ],
  ])
  let repo = SqlTickets::new(@sql.Tx::new(db))
  TicketRepository::save(
    repo,
    Assigned(id=1, subject="printer on fire", assignee="dana"),
  )
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "QUERY", "EXEC", "COMMIT"]
    ),
  )
  debug_inspect(
    db.stmts[1:],
    content=(
      #|<ArrayView:
      #|  [
      #|    (
      #|      "INSERT INTO \"ticket_assignments\" (\"ticket_id\", \"assignee\") VALUES (?, ?)",
      #|      [VInt(1), VText("dana")],
      #|    ),
      #|  ]>
    ),
  )
}

///|
/// Two saves, one transaction.
///
/// `save` brackets its own work, so on its own it is atomic. Wrapped in
/// another transaction it joins that one instead, and the two aggregates land
/// or fail together — which is the whole reason the repository is handed a
/// `Tx` rather than the driver. Note that nothing had to be rebuilt inside the
/// transaction: `repo` is the same object throughout.
async test "several saves join one enclosing transaction" {
  let db = @fake.FakeDb::new(results=[[], []])
  let tx = @sql.Tx::new(db)
  let repo = SqlTickets::new(tx)
  @sql.transaction(tx, _ => {
    TicketRepository::save(repo, Open(id=1, subject="printer on fire"))
    TicketRepository::save(repo, Open(id=2, subject="coffee machine down"))
  })
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "QUERY", "EXEC", "QUERY", "EXEC", "COMMIT"]
    ),
  )
}

///|
/// The whole save is one transaction, so a failure half way leaves nothing.
async test "a failing save rolls back" {
  let db = @fake.FakeDb::new(results=[[]])
  db.fail("simulated failure", after=2)
  let repo = SqlTickets::new(@sql.Tx::new(db))
  try {
    TicketRepository::save(
      repo,
      Closed(
        id=1,
        subject="printer on fire",
        assignee="dana",
        resolution="unplugged it",
      ),
    )
    fail("expected the driver error to propagate")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|QueryFailed(
          #|  sql="INSERT INTO \"ticket_assignments\" (\"ticket_id\", \"assignee\")\n VALUES (?, ?)",
          #|  message="simulated failure",
          #|)
        ),
      )
  }
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "QUERY", "EXEC", "ROLLBACK"]
    ),
  )
}
