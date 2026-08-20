///|
/// Which columns to read, and how to turn the values back into one MoonBit
/// value.
///
/// Kept as one type rather than two because apart they break the usual way: a
/// column is added to the projection and the decoder is not updated to match.
/// `read` is positional, which is fragile by hand — but a generator emits both
/// halves from one pass over the same field list, so they cannot drift.
pub struct Selection[Out] {
  exprs : Array[RawExpr]
  read : (Row) -> Out raise DecodeError
}

///|
/// Build a projection from raw expressions and a positional decoder.
///
/// Intended for generated code: a generator emits `exprs` and `read` from the
/// same entity definition, so their order cannot drift apart.
pub fn[Out] Selection::new(
  exprs : Array[RawExpr],
  read : (Row) -> Out raise DecodeError,
) -> Selection[Out] {
  { exprs, read }
}

///|
/// Read one column, decoded as `T`.
pub fn[T : SqlDecode] sel(c : Column[T]) -> Selection[T] {
  let key = c.name
  Selection::new([c.raw()], row => SqlDecode::decode(row[0], key))
}

///|
/// Read two columns as a pair.
pub fn[A : SqlDecode, B : SqlDecode] sel2(
  x : Column[A],
  y : Column[B],
) -> Selection[(A, B)] {
  sel(x).zip(sel(y))
}

///|
/// Read three columns as a triple.
pub fn[A : SqlDecode, B : SqlDecode, C : SqlDecode] sel3(
  x : Column[A],
  y : Column[B],
  z : Column[C],
) -> Selection[(A, B, C)] {
  sel(x)
  .zip(sel(y))
  .zip(sel(z))
  .map(t => {
    let ((a, b), c) = t
    (a, b, c)
  })
}

///|
/// Concatenate two projections, self's columns first.
pub fn[A, B] Selection::zip(
  self : Selection[A],
  other : Selection[B],
) -> Selection[(A, B)] {
  let n = self.exprs.length()
  let exprs = self.exprs.copy()
  exprs.push_iter(other.exprs.iter())
  Selection::new(exprs, row => ((self.read)(row[0:n]), (other.read)(row[n:])))
}

///|
/// Reshape what a projection decodes to, without touching which columns it
/// reads.
pub fn[A, B] Selection::map(
  self : Selection[A],
  f : (A) -> B raise DecodeError,
) -> Selection[B] {
  Selection::new(self.exprs, row => f((self.read)(row)))
}

///|
/// Collapse a pair into a value of your own.
pub fn[A, B, R] Selection::into2(
  self : Selection[(A, B)],
  f : (A, B) -> R,
) -> Selection[R] {
  self.map(t => f(t.0, t.1))
}

///|
/// Collapse a triple into a value of your own.
pub fn[A, B, C, R] Selection::into3(
  self : Selection[(A, B, C)],
  f : (A, B, C) -> R,
) -> Selection[R] {
  self.map(t => f(t.0, t.1, t.2))
}

///|
/// Read the projection as absent when the row did not match.
///
/// A LEFT JOIN reports "no match" by making every column of the right table
/// NULL, so an all-NULL row decodes to `None` rather than being forced through
/// a decoder that would reject it.
///
/// This is safe for any projection that includes a column the database never
/// leaves NULL — a primary key, for instance, which `Table::all` always covers.
/// For a hand-built projection of entirely nullable columns, say which column
/// to test with `optional_on`.
pub fn[Out] Selection::optional(self : Selection[Out]) -> Selection[Out?] {
  Selection::new(self.exprs, row => {
    if row.iter().all(v => v is VNull) {
      None
    } else {
      Some((self.read)(row))
    }
  })
}

///|
/// Read the projection as absent when one chosen column is NULL.
///
/// `key` indexes into this projection's own columns, counting from zero.
pub fn[Out] Selection::optional_on(
  self : Selection[Out],
  key~ : Int,
) -> Selection[Out?] {
  Selection::new(self.exprs, row => {
    if row[key] is VNull {
      None
    } else {
      Some((self.read)(row))
    }
  })
}
