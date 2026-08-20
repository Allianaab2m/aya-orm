// The expression layer.
//
// `RawExpr` is the tree the emitter walks. `Expr[T]` and `Column[T]` are thin
// typed wrappers over it: the `T` is a phantom that never reaches the SQL and
// exists only to keep comparisons honest.

///|
/// Untyped expression tree. Whatever type the wrappers above it carried has
/// been erased by the time an expression reaches here.
pub enum RawExpr {
  Col(tbl~ : String, name~ : String)
  Lit(SqlValue)
  Bin(BinOp, RawExpr, RawExpr)
  Unary(String, RawExpr)
  InList(RawExpr, Array[SqlValue])
  Agg(String, RawExpr?)
} derive(Debug)

///|
pub enum BinOp {
  Eq
  Ne
  Gt
  Gte
  Lt
  Lte
  And
  Or
} derive(Debug, Eq)

///|
pub impl Show for BinOp with fn to_string(self) -> String {
  match self {
    BinOp::Eq => "="
    BinOp::Ne => "<>"
    BinOp::Gt => ">"
    BinOp::Gte => ">="
    BinOp::Lt => "<"
    BinOp::Lte => "<="
    BinOp::And => "AND"
    BinOp::Or => "OR"
  }
}

///|
/// A typed expression. `T` is what the expression evaluates to in SQL terms;
/// nothing at runtime carries it.
pub struct Expr[T](RawExpr)

///|
pub fn[T] Expr::raw(self : Expr[T]) -> RawExpr {
  let Expr(r) = self
  r
}

///|
/// A reference to one column of one table.
///
/// Separate from `Expr[T]` because a column also has a name, which `sel`,
/// `Binding` and `Update::set` need and a general expression cannot supply.
pub struct Column[T] {
  /// Alias of the table the column belongs to, as it appears in `FROM`.
  tbl : String
  /// Column name in the database.
  name : String
}

///|
pub fn[T] Column::new(tbl~ : String, name~ : String) -> Column[T] {
  { tbl, name }
}

///|
pub fn[T] Column::expr(self : Column[T]) -> Expr[T] {
  Expr(Col(tbl=self.tbl, name=self.name))
}

///|
pub fn[T] Column::raw(self : Column[T]) -> RawExpr {
  self.expr().raw()
}

///|
/// Reinterpret a column as nullable.
///
/// The right-hand side of a LEFT JOIN can be absent, so its columns decode as
/// `T?` even though the entity declares them as `T`.
pub fn[T] Column::nullable(self : Column[T]) -> Column[T?] {
  { tbl: self.tbl, name: self.name }
}

// Comparisons.
//
// The six operators differ only in which `BinOp` they carry, so the shared
// half — lifting the value into a bound literal — is written once in `cmp`.

///|
fn[T : SqlEncode] Expr::cmp(self : Expr[T], op : BinOp, v : T) -> Expr[Bool] {
  Expr(Bin(op, self.raw(), Lit(v.to_sql_value())))
}

///|
pub fn[T : SqlEncode] Expr::eq(self : Expr[T], v : T) -> Expr[Bool] {
  self.cmp(BinOp::Eq, v)
}

///|
pub fn[T : SqlEncode] Expr::ne(self : Expr[T], v : T) -> Expr[Bool] {
  self.cmp(BinOp::Ne, v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::gt(self : Expr[T], v : T) -> Expr[Bool] {
  self.cmp(BinOp::Gt, v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::gte(self : Expr[T], v : T) -> Expr[Bool] {
  self.cmp(BinOp::Gte, v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::lt(self : Expr[T], v : T) -> Expr[Bool] {
  self.cmp(BinOp::Lt, v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::lte(self : Expr[T], v : T) -> Expr[Bool] {
  self.cmp(BinOp::Lte, v)
}

///|
/// Compare two expressions, as in a join condition.
pub fn[T] Expr::eq_col(self : Expr[T], other : Expr[T]) -> Expr[Bool] {
  Expr(Bin(BinOp::Eq, self.raw(), other.raw()))
}

///|
pub fn[T : SqlEncode] Expr::in_(self : Expr[T], vs : Array[T]) -> Expr[Bool] {
  Expr(InList(self.raw(), vs.map(v => v.to_sql_value())))
}

///|
pub fn[T] Expr::is_none(self : Expr[T?]) -> Expr[Bool] {
  Expr(Unary("IS NULL", self.raw()))
}

///|
pub fn[T] Expr::is_some(self : Expr[T?]) -> Expr[Bool] {
  Expr(Unary("IS NOT NULL", self.raw()))
}

///|
pub impl BitAnd for Expr[Bool] with fn land(self, other) {
  Expr(Bin(BinOp::And, self.raw(), other.raw()))
}

///|
pub impl BitOr for Expr[Bool] with fn lor(self, other) {
  Expr(Bin(BinOp::Or, self.raw(), other.raw()))
}

// Ordering.

///|
pub(all) enum Dir {
  Asc
  Desc
} derive(Debug, Eq)

///|
pub impl Show for Dir with fn to_string(self) -> String {
  match self {
    Asc => "ASC"
    Desc => "DESC"
  }
}

///|
/// One key of an ORDER BY clause.
pub struct OrderKey {
  expr : RawExpr
  dir : Dir
}

///|
pub fn[T : SqlOrd] Expr::asc(self : Expr[T]) -> OrderKey {
  { expr: self.raw(), dir: Dir::Asc }
}

///|
pub fn[T : SqlOrd] Expr::desc(self : Expr[T]) -> OrderKey {
  { expr: self.raw(), dir: Dir::Desc }
}

// Column comparisons.
//
// A column is the overwhelmingly common left-hand side of a comparison, so it
// gets the operators directly rather than making every call site lift it with
// `expr()` first. Each one is the `Expr` operator with the column lifted.

///|
pub fn[T : SqlEncode] Column::eq(self : Column[T], v : T) -> Expr[Bool] {
  self.expr().eq(v)
}

///|
pub fn[T : SqlEncode] Column::ne(self : Column[T], v : T) -> Expr[Bool] {
  self.expr().ne(v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Column::gt(
  self : Column[T],
  v : T,
) -> Expr[Bool] {
  self.expr().gt(v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Column::gte(
  self : Column[T],
  v : T,
) -> Expr[Bool] {
  self.expr().gte(v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Column::lt(
  self : Column[T],
  v : T,
) -> Expr[Bool] {
  self.expr().lt(v)
}

///|
pub fn[T : SqlEncode + SqlOrd] Column::lte(
  self : Column[T],
  v : T,
) -> Expr[Bool] {
  self.expr().lte(v)
}

///|
/// Compare two columns, as in a join condition.
pub fn[T] Column::eq_col(self : Column[T], other : Column[T]) -> Expr[Bool] {
  self.expr().eq_col(other.expr())
}

///|
pub fn[T : SqlEncode] Column::in_(
  self : Column[T],
  vs : Array[T],
) -> Expr[Bool] {
  self.expr().in_(vs)
}

///|
pub fn[T] Column::is_none(self : Column[T?]) -> Expr[Bool] {
  self.expr().is_none()
}

///|
pub fn[T] Column::is_some(self : Column[T?]) -> Expr[Bool] {
  self.expr().is_some()
}

///|
pub fn[T : SqlOrd] Column::asc(self : Column[T]) -> OrderKey {
  self.expr().asc()
}

///|
pub fn[T : SqlOrd] Column::desc(self : Column[T]) -> OrderKey {
  self.expr().desc()
}
