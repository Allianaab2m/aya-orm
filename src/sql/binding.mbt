///|
/// The write-side counterpart of `Selection`.
///
/// `Selection` says which columns to read and how to turn a result row into a
/// value; `Binding` says which columns to write and how to turn a value back
/// into a row. Keeping the pair symmetric means a generator can emit both from
/// the same field list, so the two can never disagree about column order.
pub struct Binding[In] {
  columns : Array[String]
  write : (In) -> Array[SqlValue]
}

///|
/// Build a binding from column names and an encoder.
///
/// `write` must return one value per entry of `columns`, in the same order.
pub fn[In] Binding::new(
  columns : Array[String],
  write : (In) -> Array[SqlValue],
) -> Binding[In] {
  { columns, write }
}

///|
/// Drop columns from a binding, keeping declaration order.
///
/// The usual reason is an auto-increment primary key: the entity carries an
/// `id` field, but the INSERT must let the database assign it.
pub fn[In] Binding::without(
  self : Binding[In],
  names : Array[String],
) -> Binding[In] {
  let keep = []
  for i, c in self.columns {
    if !names.contains(c) {
      keep.push(i)
    }
  }
  {
    columns: keep.map(i => self.columns[i]),
    write: v => {
      let all = (self.write)(v)
      keep.map(i => all[i])
    },
  }
}

///|
/// Rewrite a binding to accept a different input type.
///
/// The contravariant counterpart of `Selection::map`. Together they form the
/// seam between the row type and a domain type: `Selection::map` turns rows
/// into domain values on the way out, `Binding::contramap` turns domain values
/// back into rows on the way in.
///
/// `f` is total, unlike the reading direction, because a domain value is the
/// more constrained of the two: flattening it into a row cannot fail.
pub fn[A, B] Binding::contramap(self : Binding[A], f : (B) -> A) -> Binding[B] {
  { columns: self.columns, write: v => (self.write)(f(v)) }
}
