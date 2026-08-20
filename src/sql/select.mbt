///|
/// A pair of projection and the corresponding decoder.
pub struct Selection[Out] {
  exprs : Array[RawExpr]
  read : (ArrayView[SqlValue]) -> Out raise DecodeError
}

///|
pub(open) trait SqlDecode {
  fn decode(SqlValue, String) -> Self raise DecodeError
}

///|
pub impl SqlDecode for Int with fn decode(v, k) {
  match v {
    VInt(n) => n.to_int()
    _ => raise TypeMismatch(column=k, expected="Int")
  }
}

///|
pub impl SqlDecode for String with fn decode(v, k) {
  match v {
    VText(s) => s
    _ => raise TypeMismatch(column=k, expected="String")
  }
}

///|
/// Numbers arrive as whichever of the two numeric shapes the driver chose, so
/// an integral column read as a `Double` is accepted rather than rejected.
pub impl SqlDecode for Double with fn decode(v, k) {
  match v {
    VDouble(d) => d
    VInt(n) => n.to_double()
    _ => raise TypeMismatch(column=k, expected="Double")
  }
}

///|
pub impl SqlDecode for Bool with fn decode(v, k) {
  match v {
    VBool(b) => b
    VInt(n) => n != 0L
    _ => raise TypeMismatch(column=k, expected="Bool")
  }
}

///|
pub impl[T : SqlDecode] SqlDecode for T? with fn decode(v, k) {
  match v {
    VNull => None
    other => {
      let x : T = SqlDecode::decode(other, k)
      Some(x)
    }
  }
}

///|
/// Build a projection directly from raw expressions and a positional decoder.
/// Intended for generated code: a generator emits `exprs` and `read` from the
/// same entity definition, so their order cannot drift apart.
pub fn[Out] Selection::new(
  exprs : Array[RawExpr],
  read : (ArrayView[SqlValue]) -> Out raise DecodeError,
) -> Selection[Out] {
  { exprs, read }
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
  {
    exprs: self.exprs,
    read: row => {
      let mut all_null = true
      for v in row {
        if !(v is VNull) {
          all_null = false
          break
        }
      }
      if all_null {
        None
      } else {
        Some((self.read)(row))
      }
    },
  }
}

///|
/// Read the projection as absent when one chosen column is NULL.
///
/// `key` indexes into this projection's own columns, counting from zero.
pub fn[Out] Selection::optional_on(
  self : Selection[Out],
  key~ : Int,
) -> Selection[Out?] {
  {
    exprs: self.exprs,
    read: row => if row[key] is VNull { None } else { Some((self.read)(row)) },
  }
}

///|
/// Concatenate two projections horizontally, with self's columns first, followed by other's columns
pub fn[A, B] Selection::zip(
  self : Selection[A],
  other : Selection[B],
) -> Selection[(A, B)] {
  let n = self.exprs.length()
  let exprs : Array[RawExpr] = []
  exprs.push_iter(self.exprs.iter())
  exprs.push_iter(other.exprs.iter())
  { exprs, read: row => ((self.read)(row[0:n]), (other.read)(row[n:])) }
}

///|
/// map the output of a projection to another type, by applying a function to the output of the decoder
pub fn[A, B] Selection::map(
  self : Selection[A],
  f : (A) -> B raise DecodeError,
) -> Selection[B] {
  { exprs: self.exprs, read: row => f((self.read)(row)) }
}

///|
/// primitive
pub fn[T : SqlDecode] sel(c : Column[T]) -> Selection[T] {
  let key = c.name()
  {
    exprs: [Col(tbl=c.tbl(), name=c.name())],
    read: row => SqlDecode::decode(row[0], key),
  }
}

///|
pub fn[A : SqlDecode, B : SqlDecode] sel2(
  x : Column[A],
  y : Column[B],
) -> Selection[(A, B)] {
  sel(x).zip(sel(y))
}

///|
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
pub fn[A, B, R] Selection::into2(
  self : Selection[(A, B)],
  f : (A, B) -> R,
) -> Selection[R] {
  self.map(t => f(t.0, t.1))
}

///|
pub fn[A, B, C, R] Selection::into3(
  self : Selection[(A, B, C)],
  f : (A, B, C) -> R,
) -> Selection[R] {
  self.map(t => f(t.0, t.1, t.2))
}
