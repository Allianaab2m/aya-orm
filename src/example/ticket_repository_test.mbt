///|
/// Loading the aggregate is a single statement, whatever phase it is in.
test "one query loads the whole aggregate" {
  let repo = SqlTickets::new(StubDb::new())
  let _ = TicketRepository::find(repo, 1)
  inspect(
    (ticket_query() |> @sql.Query::filter(c => c.0.0.id.eq(1))).to_sql().0,
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
    |> @sql.Query::filter(c => c.0.1.col(a => a.ticket_id).is_none())).to_sql().0,
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
test "saving an open ticket inserts one row" {
  let db = StubDb::new(results=[[]])
  let repo = SqlTickets::new(db)
  TicketRepository::save(repo, Open(id=1, subject="printer on fire"))
  debug_inspect(
    db.log,
    content=(
      #|["BEGIN", "QUERY", "EXEC", "COMMIT"]
    ),
  )
  debug_inspect(
    db.stmts,
    content=(
      #|["INSERT INTO \"tickets\" (\"id\", \"subject\")"]
    ),
  )
}

///|
/// Saving a ticket that has moved on inserts only the phase rows that are
/// missing: the base row is already there, so it is left alone.
test "saving a transition inserts only what is new" {
  // The find inside `save` reports an already-open ticket.
  let db = StubDb::new(results=[
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
  let repo = SqlTickets::new(db)
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
    db.stmts,
    content=(
      #|["INSERT INTO \"ticket_assignments\" (\"ticket_id\", \"assignee\")"]
    ),
  )
}

///|
/// The whole save is one transaction, so a failure half way leaves nothing.
test "a failing save rolls back" {
  let db = StubDb::new(results=[[]])
  db.fail_after = Some(1)
  let repo = SqlTickets::new(db)
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
