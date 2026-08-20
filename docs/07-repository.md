# 7. The Repository pattern

[← Execution](06-execution.md) · [Schema →](08-schema.md)

aya provides nothing for this. A repository is ordinary application code, and
this chapter is about the shape that code takes when aya is underneath it.

> The code here is illustrative rather than lifted from `src/example`, which
> keeps only two entities. See [design notes](09-design.md) for why.

## The shape falls out of MoonBit's traits

A trait method cannot introduce type parameters of its own, so **a generic
`Repository[T, ID]` cannot be written**. What you get instead is an interface
per aggregate, in domain vocabulary — and that is the better shape anyway:
`unassigned` says something a generic `find_by(criteria)` cannot.

```moonbit
// Port: the domain's vocabulary. No dependency on aya.
pub(open) trait TicketRepository {
  async fn find(Self, Int) -> Ticket?
  async fn save(Self, Ticket) -> Unit
  async fn unassigned(Self) -> Array[Ticket]
}

// Adapter: generic over the driver, holding a Tx over one as its connection.
struct SqlTickets[D] {
  db : @aya.Tx[D]
}

pub fn[D] SqlTickets::new(db : @aya.Tx[D]) -> SqlTickets[D] {
  { db, }
}

pub impl[D : @aya.Driver] TicketRepository for SqlTickets[D] with fn find(self, id) {
  (ticket_query() |> @aya.Query::filter(j => j.ticket.id.eq(id))).first(self.db)
}
```

The `impl` needs `pub`. Without it, callers outside the package get
"no `impl` is defined".

**The field is a `Tx[D]`, not a `D`.** That is what lets `save` bracket its own
work without knowing whether anything else already has — see
[chapter 6](06-execution.md).

## When the aggregate is spread over several tables

This is where a repository earns its keep. Take an aggregate split into phase
tables: one for the entity's invariant data, one per phase holding only the
facts that phase establishes. Every column is NOT NULL, and the FK chain forces
the phases to happen in order.

```
tickets(id, subject)
ticket_assignments(ticket_id -> tickets.id, assignee)
ticket_closures(ticket_id -> ticket_assignments.ticket_id, resolution)
```

`find` is a single statement with two outer joins.

```moonbit
pub struct TicketJoin {
  ticket     : TicketCols
  assignment : @aya.Nullable[AssignmentCols, AssignmentRow]
  closure    : @aya.Nullable[ClosureCols, ClosureRow]
}

pub fn ticket_query() -> @aya.Query[TicketJoin, Ticket] {
  @aya.from(TicketRow::table())
  |> @aya.Query::left_join(AssignmentRow::table(), (t, a) => t.id.eq_col(a.ticket_id))
  |> @aya.Query::left_join(ClosureRow::table(), (c, cl) => c.0.id.eq_col(cl.ticket_id))
  |> @aya.Query::map_cols(c => { ticket: c.0.0, assignment: c.0.1, closure: c.1 })
  |> @aya.Query::map(j => TicketRow::all(j.ticket)
    .zip(j.assignment.row())
    .zip(j.closure.row())
    .map(assemble))
}
```

The nesting is confined to the one `map_cols` line. Everything after reads
`j.assignment`, not `c.0.1`.

**Which phase rows came back is the state.** No discriminator column exists.

```moonbit
fn assemble(
  parts : ((TicketRow, AssignmentRow?), ClosureRow?),
) -> Ticket raise @aya.DecodeError {
  let ((base, assignment), closure) = parts
  match (assignment, closure) {
    (None, None) => Open(id=base.id, subject=base.subject)
    (Some(a), None) => Assigned(id=base.id, subject=base.subject, assignee=a.assignee)
    (Some(a), Some(c)) =>
      Closed(id=base.id, subject=base.subject, assignee=a.assignee, resolution=c.resolution)
    // The FK chain makes a closure without an assignment impossible in the
    // database. The type cannot say so, hence the branch.
    (None, Some(_)) => raise @aya.Malformed("ticket \{base.id}: closed but never assigned")
  }
}
```

| Rows returned | Aggregate rebuilt |
|---|---|
| base only | `Open(id=1, subject="printer on fire")` |
| base + assignment | `Assigned(..., assignee="dana")` |
| all three | `Closed(..., resolution="unplugged it")` |

A domain-meaningful query is the *absence* of a phase row:

```moonbit
|> @aya.Query::filter(j => j.assignment.col(a => a.ticket_id).is_none())
// -> WHERE ta."ticket_id" IS NULL
```

## `save` is where the ungenerable work lives

Phase rows are immutable facts, so saving is additive: read what is there and
insert only what is missing.

```moonbit
pub impl[D : @aya.Driver] TicketRepository for SqlTickets[D] with fn save(self, ticket) {
  @aya.transaction(self.db, conn => {
    let id = ticket.id()
    let before = self.find(id)
    if before is None {
      @aya.insert(TicketRow::table(), { id, subject: ticket.subject() }).run(conn) |> ignore
    }
    let recorded_assignee = match before { Some(t) => t.assignee(); None => None }
    if ticket.assignee() is Some(assignee) && recorded_assignee is None {
      @aya.insert(AssignmentRow::table(), { ticket_id: id, assignee }).run(conn) |> ignore
    }
    let recorded_resolution = match before { Some(t) => t.resolution(); None => None }
    if ticket.resolution() is Some(resolution) && recorded_resolution is None {
      @aya.insert(ClosureRow::table(), { ticket_id: id, resolution }).run(conn) |> ignore
    }
  })
}
```

| Operation | Statements issued |
|---|---|
| save a new `Open` | `INSERT INTO "tickets" ("id", "subject")` |
| `Open` to `Assigned` | `INSERT INTO "ticket_assignments" ("ticket_id", "assignee")` |
| failure part way | `["BEGIN", "QUERY", "EXEC", "ROLLBACK"]` |

The base row is not rewritten. This is **where the aggregate's shape meets the
tables'**, and it is the part a generator cannot write.

## Wiring

```moonbit
let db = @aya.Tx::new(@sqlite.Sqlite::open("app.db"))
let tickets = SqlTickets::new(db)
let users = SqlUsers::new(db)

@aya.transaction(db, _ => {
  tickets.save(a)
  users.save(b)
})   // one BEGIN, one COMMIT
```

The shared depth is the whole mechanism: give two repositories two different
`Tx` values over the same connection and they will ask the database to `BEGIN`
twice, which SQLite rejects outright. Nothing has to be rebuilt inside the
transaction — the repositories above are the same objects throughout.

## Testing

Because the adapter is generic over `D : @aya.Driver`, the fake goes straight
in — no database, no fixtures, and what gets asserted is the statements that
went out:

```moonbit
let db = @fake.FakeDb::new(counts=[1, 1])
let repo = SqlTickets::new(@aya.Tx::new(db))
repo.save(Open(id=1, subject="printer on fire"))
db.log  // ["BEGIN", "QUERY", "EXEC", "COMMIT"]
```

---

[← Execution](06-execution.md) · [Schema →](08-schema.md)
