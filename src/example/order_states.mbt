///|
/// One table per state, so the schema itself rejects the combinations the
/// domain type rejects.
///
/// The single-table version in `orders.mbt` has to make `submitted_at` and
/// `tracking` nullable, which lets the database hold a shipped order with no
/// tracking number. Here every column is NOT NULL by construction: a column
/// only exists in the states that actually have it.
#cairn.table(name="order_drafts", alias="d", cols="DraftCols")
pub(all) struct DraftRow {
  #cairn.id
  id : Int
  items : Int
} derive(Debug, Eq)

///|
#cairn.table(name="order_submitted", alias="s", cols="SubmittedCols")
pub(all) struct SubmittedRow {
  #cairn.id
  id : Int
  items : Int
  submitted_at : String
} derive(Debug, Eq)

///|
#cairn.table(name="order_shipped", alias="p", cols="ShippedCols")
pub(all) struct ShippedRow {
  #cairn.id
  id : Int
  items : Int
  submitted_at : String
  tracking : String
} derive(Debug, Eq)

///|
/// Lifting a row into the domain type is now total in both directions.
///
/// Compare `Order::of_row` in `orders.mbt`, which needs a failure branch for
/// rows the domain type has no state for. That branch has nowhere to live
/// here, because such a row cannot be stored in the first place.
pub fn DraftRow::to_order(self : DraftRow) -> Order {
  Draft(id=self.id, items=self.items)
}

///|
pub fn SubmittedRow::to_order(self : SubmittedRow) -> Order {
  Submitted(id=self.id, items=self.items, submitted_at=self.submitted_at)
}

///|
pub fn ShippedRow::to_order(self : ShippedRow) -> Order {
  Shipped(
    id=self.id,
    items=self.items,
    submitted_at=self.submitted_at,
    tracking=self.tracking,
  )
}

///|
/// Reading one state as the domain type.
///
/// Each table stays typed by its own row: `Table[DraftCols, DraftRow]` rather
/// than `Table[_, Order]`. Typing the table by `Order` would make the write
/// direction partial, since only a `Draft` belongs in `order_drafts`, and the
/// per-state schema exists precisely to keep that from being expressible.
pub fn drafts_as_orders() -> @sql.Query[DraftCols, Order] {
  @sql.from(DraftRow::table())
  |> @sql.Query::map(c => DraftRow::all(c).map(r => r.to_order()))
}

///|
pub fn submitted_as_orders() -> @sql.Query[SubmittedCols, Order] {
  @sql.from(SubmittedRow::table())
  |> @sql.Query::map(c => SubmittedRow::all(c).map(r => r.to_order()))
}

///|
pub fn shipped_as_orders() -> @sql.Query[ShippedCols, Order] {
  @sql.from(ShippedRow::table())
  |> @sql.Query::map(c => ShippedRow::all(c).map(r => r.to_order()))
}

///|
/// Moving an order between states is a delete plus an insert.
///
/// The two statements have to land together, which is what a transaction is
/// for. cairn has no execution layer yet, so this returns the pair and leaves
/// running them atomically to the caller — the cost the per-state schema
/// trades for its stronger guarantees.
pub fn submit(
  draft : DraftRow,
  at~ : String,
) -> ((String, Array[@sql.SqlValue]), (String, Array[@sql.SqlValue])) raise @sql.StatementError {
  let remove = @sql.delete(DraftRow::table(), d => d.id.eq(draft.id)).to_sql()
  let add = @sql.insert(SubmittedRow::table(), {
    id: draft.id,
    items: draft.items,
    submitted_at: at,
  }).to_sql()
  (remove, add)
}
