///|
/// Assemble the aggregate from the base row plus whichever phase rows matched.
///
/// Which phases are present *is* the state, so no discriminator column is
/// needed and none is stored.
fn assemble(
  parts : ((TicketRow, AssignmentRow?), ClosureRow?),
) -> Ticket raise @sql.DecodeError {
  let ((base, assignment), closure) = parts
  match (assignment, closure) {
    (None, None) => Open(id=base.id, subject=base.subject)
    (Some(a), None) =>
      Assigned(id=base.id, subject=base.subject, assignee=a.assignee)
    (Some(a), Some(c)) =>
      Closed(
        id=base.id,
        subject=base.subject,
        assignee=a.assignee,
        resolution=c.resolution,
      )
    // The FK chain makes a closure without an assignment impossible in the
    // database. The type cannot say so, hence the branch.
    (None, Some(_)) =>
      raise @sql.Malformed("ticket \{base.id}: closed but never assigned")
  }
}

///|
/// The shape of the joined row set, with the tables named.
///
/// Chained joins hand back nested tuples. Collapsing that once, right after the
/// joins, is what keeps every later step reading `j.assignment` instead of
/// `c.0.1` — and keeps this function's own signature legible.
pub struct TicketJoin {
  ticket : TicketCols
  assignment : @sql.Nullable[AssignmentCols, AssignmentRow]
  closure : @sql.Nullable[ClosureCols, ClosureRow]
}

///|
/// One query that loads the whole aggregate, however far along it is.
///
/// Two outer joins, so both phase tables come back as `Nullable` and can only
/// be read as optional rows.
pub fn ticket_query() -> @sql.Query[TicketJoin, Ticket] {
  @sql.from(TicketRow::table())
  |> @sql.Query::left_join(AssignmentRow::table(), (t, a) => {
    t.id.eq_col(a.ticket_id)
  })
  |> @sql.Query::left_join(ClosureRow::table(), (c, cl) => {
    c.0.id.eq_col(cl.ticket_id)
  })
  |> @sql.Query::map_cols(c => {
    ticket: c.0.0,
    assignment: c.0.1,
    closure: c.1,
  })
  |> @sql.Query::map(j => {
    TicketRow::all(j.ticket)
    .zip(j.assignment.row())
    .zip(j.closure.row())
    .map(assemble)
  })
}

///|
/// The port, stated in domain terms.
///
/// Not a generic `Repository[T, ID]`: MoonBit traits take no parameters of
/// their own, and in any case an aggregate-specific interface is the shape
/// worth having — `unassigned` says something a generic `find_by` cannot.
pub(open) trait TicketRepository {
  async fn find(Self, Int) -> Ticket?
  async fn save(Self, Ticket) -> Unit
  async fn unassigned(Self) -> Array[Ticket]
}

///|
/// The adapter. Generic over the driver, holding a `Tx` over one as its
/// connection.
///
/// A `Tx` rather than the driver itself so that the transaction `save` opens
/// joins whatever transaction the caller has already opened. Every repository
/// over the same connection has to be handed the *same* `Tx` for that to work,
/// which is why it is a constructor argument rather than something built here.
struct SqlTickets[D] {
  db : @sql.Tx[D]
}

///|
pub fn[D] SqlTickets::new(db : @sql.Tx[D]) -> SqlTickets[D] {
  { db, }
}

///|
pub impl[D : @sql.Driver] TicketRepository for SqlTickets[D] with fn find(
  self,
  id,
) {
  (ticket_query() |> @sql.Query::filter(j => j.ticket.id.eq(id))).first(self.db)
}

///|
pub impl[D : @sql.Driver] TicketRepository for SqlTickets[D] with fn unassigned(
  self,
) {
  // Reaching a column of an outer-joined table yields `Column[Int?]`, which is
  // exactly what "no assignment row matched" needs to be tested against.
  (ticket_query()
  |> @sql.Query::filter(j => j.assignment.col(a => a.ticket_id).is_none())).run(
    self.db,
  )
}

///|
/// Persist the aggregate, inserting only the phase rows that are not there yet.
///
/// Phase rows are immutable facts, so saving is additive and the whole thing
/// fits in one transaction. This is the work that cannot be generated: it is
/// where the aggregate's shape meets the tables'.
pub impl[D : @sql.Driver] TicketRepository for SqlTickets[D] with fn save(
  self,
  ticket,
) {
  @sql.transaction(self.db, conn => {
    let id = ticket.id()
    let before = self.find(id)
    if before is None {
      @sql.insert(TicketRow::table(), { id, subject: ticket.subject() }).run(
        conn,
      )
      |> ignore
    }
    let recorded_assignee = match before {
      Some(t) => t.assignee()
      None => None
    }
    if ticket.assignee() is Some(assignee) && recorded_assignee is None {
      @sql.insert(AssignmentRow::table(), { ticket_id: id, assignee }).run(conn)
      |> ignore
    }
    let recorded_resolution = match before {
      Some(t) => t.resolution()
      None => None
    }
    if ticket.resolution() is Some(resolution) && recorded_resolution is None {
      @sql.insert(ClosureRow::table(), { ticket_id: id, resolution }).run(conn)
      |> ignore
    }
  })
}
