// A worked repository over an aggregate that is stored across several tables.
//
// The schema is the phase-table shape: one table for the entity's invariant
// data, and one per phase holding only the facts that phase establishes. Every
// column is NOT NULL, and the FK chain forces the phases to happen in order.
//
//   tickets(id, subject)
//   ticket_assignments(ticket_id -> tickets.id, assignee)
//   ticket_closures(ticket_id -> ticket_assignments.ticket_id, resolution)

///|
#cairn.table(name="tickets", alias="t", cols="TicketCols")
pub(all) struct TicketRow {
  #cairn.id
  id : Int
  subject : String
} derive(Debug, Eq)

///|
#cairn.table(name="ticket_assignments", alias="ta", cols="AssignmentCols")
pub(all) struct AssignmentRow {
  #cairn.id
  ticket_id : Int
  assignee : String
} derive(Debug, Eq)

///|
#cairn.table(name="ticket_closures", alias="tc", cols="ClosureCols")
pub(all) struct ClosureRow {
  #cairn.id
  ticket_id : Int
  resolution : String
} derive(Debug, Eq)

///|
/// The aggregate. This is what the rest of the program deals in; the three row
/// types above never leave this file.
pub(all) enum Ticket {
  Open(id~ : Int, subject~ : String)
  Assigned(id~ : Int, subject~ : String, assignee~ : String)
  Closed(id~ : Int, subject~ : String, assignee~ : String, resolution~ : String)
} derive(Debug, Eq)

///|
pub fn Ticket::id(self : Ticket) -> Int {
  match self {
    Open(id~, ..) | Assigned(id~, ..) | Closed(id~, ..) => id
  }
}

///|
pub fn Ticket::subject(self : Ticket) -> String {
  match self {
    Open(subject~, ..) | Assigned(subject~, ..) | Closed(subject~, ..) =>
      subject
  }
}

///|
/// Which phase rows this state implies. Used by `save` to work out what is
/// missing rather than blindly rewriting everything.
pub fn Ticket::assignee(self : Ticket) -> String? {
  match self {
    Open(..) => None
    Assigned(assignee~, ..) | Closed(assignee~, ..) => Some(assignee)
  }
}

///|
pub fn Ticket::resolution(self : Ticket) -> String? {
  match self {
    Closed(resolution~, ..) => Some(resolution)
    _ => None
  }
}
