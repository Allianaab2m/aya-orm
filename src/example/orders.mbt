///|
/// The row type: the flat shape of one row of `orders`, and nothing more.
///
/// It exists to describe storage. It deliberately does not try to be the thing
/// the rest of the program works with — see `Order` below, which is a sum type
/// the table cannot express directly.
#aya.table(name="orders", alias="o", cols="OrderCols")
pub(all) struct OrderRow {
  #aya.id
  id : Int
  items : Int
  status : String
  submitted_at : String?
  tracking : String?
} derive(Debug, Eq)

///|
/// The domain entity: an order is in exactly one state, and each state carries
/// exactly the data that state has.
///
/// There is no 1-1 correspondence with `OrderRow`. The row has to keep
/// `submitted_at` and `tracking` nullable because a draft has neither, while
/// the domain type makes those fields unconditional in the states that own
/// them. Illegal combinations — a shipped order with no tracking number — are
/// unrepresentable here but perfectly representable in the table.
pub(all) enum Order {
  Draft(id~ : Int, items~ : Int)
  Submitted(id~ : Int, items~ : Int, submitted_at~ : String)
  Shipped(id~ : Int, items~ : Int, submitted_at~ : String, tracking~ : String)
} derive(Debug, Eq)

///|
/// Rebuild the domain value from a stored row.
///
/// This direction can fail: the table can hold combinations the domain type
/// rejects, and that has to surface rather than be papered over.
pub fn Order::of_row(r : OrderRow) -> Order raise @sql.DecodeError {
  match (r.status, r.submitted_at, r.tracking) {
    ("draft", _, _) => Draft(id=r.id, items=r.items)
    ("submitted", Some(at), _) =>
      Submitted(id=r.id, items=r.items, submitted_at=at)
    ("shipped", Some(at), Some(t)) =>
      Shipped(id=r.id, items=r.items, submitted_at=at, tracking=t)
    _ =>
      raise @sql.Malformed(
        "orders id=\{r.id}: status \{r.status} with submitted_at=\{r.submitted_at is Some(_)} tracking=\{r.tracking is Some(_)}",
      )
  }
}

///|
/// Flatten the domain value back into a row.
///
/// Total, because every legal `Order` has a row representation. The nulls that
/// the row needs are supplied here, in one place, rather than being scattered
/// across call sites.
pub fn Order::to_row(self : Order) -> OrderRow {
  match self {
    Draft(id~, items~) =>
      { id, items, status: "draft", submitted_at: None, tracking: None }
    Submitted(id~, items~, submitted_at~) =>
      {
        id,
        items,
        status: "submitted",
        submitted_at: Some(submitted_at),
        tracking: None,
      }
    Shipped(id~, items~, submitted_at~, tracking~) =>
      {
        id,
        items,
        status: "shipped",
        submitted_at: Some(submitted_at),
        tracking: Some(tracking),
      }
  }
}

///|
/// The table the rest of the program uses. It is typed by the domain entity,
/// not by the row.
///
/// Everything storage-shaped comes from the generated `OrderRow` metadata; the
/// only things written by hand are the two mappings, which is where the domain
/// knowledge actually lives.
pub fn orders() -> @sql.Table[OrderCols, Order] {
  OrderRow::table_of(Order::of_row, Order::to_row)
}
