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
/// Deleted type expression tree. No generics are included.
pub enum RawExpr {
  Col(tbl~ : String, name~ : String)
  Lit(SqlValue)
  Bin(BinOp, RawExpr, RawExpr)
  Unary(String, RawExpr)
  InList(RawExpr, Array[SqlValue])
  Agg(String, RawExpr?)
} derive(Debug) ///|
/// Typed expression. T is phantom type for the type of the expression.

///|
pub struct Expr[T](RawExpr)

///|
/// Column reference
pub struct Column[T](String, String)

///|
pub fn[T] Column::new(tbl~ : String, name~ : String) -> Column[T] {
  Column(tbl, name)
}

///|
pub fn[T] Column::expr(self : Column[T]) -> Expr[T] {
  let Column(tbl, name) = self
  Expr(Col(tbl~, name~))
}

///|
pub fn[T] Column::tbl(self : Column[T]) -> String {
  let Column(tbl, _) = self
  tbl
}

///|
pub fn[T] Column::name(self : Column[T]) -> String {
  let Column(_, name) = self
  name
}

///|
pub fn[T] Expr::raw(self : Expr[T]) -> RawExpr {
  let Expr(r) = self
  r
}

// comparisons

///|
pub fn[T : SqlEncode] Expr::eq(self : Expr[T], v : T) -> Expr[Bool] {
  Expr(Bin(BinOp::Eq, self.raw(), Lit(v.to_sql_value())))
}

///|
pub fn[T : SqlEncode] Expr::ne(self : Expr[T], v : T) -> Expr[Bool] {
  Expr(Bin(BinOp::Ne, self.raw(), Lit(v.to_sql_value())))
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::gt(self : Expr[T], v : T) -> Expr[Bool] {
  Expr(Bin(BinOp::Gt, self.raw(), Lit(SqlEncode::to_sql_value(v))))
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::gte(self : Expr[T], v : T) -> Expr[Bool] {
  Expr(Bin(BinOp::Gte, self.raw(), Lit(SqlEncode::to_sql_value(v))))
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::lt(self : Expr[T], v : T) -> Expr[Bool] {
  Expr(Bin(BinOp::Lt, self.raw(), Lit(SqlEncode::to_sql_value(v))))
}

///|
pub fn[T : SqlEncode + SqlOrd] Expr::lte(self : Expr[T], v : T) -> Expr[Bool] {
  Expr(Bin(BinOp::Lte, self.raw(), Lit(SqlEncode::to_sql_value(v))))
}

///|
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

// logical combinations

///|
pub impl BitAnd for Expr[Bool] with fn land(self, other) {
  Expr(Bin(BinOp::And, self.raw(), other.raw()))
}

///|
pub impl BitOr for Expr[Bool] with fn lor(self, other) {
  Expr(Bin(BinOp::Or, self.raw(), other.raw()))
}

// aggregates, order

///|
pub fn count() -> Expr[Int] {
  Expr(Agg("COUNT", None))
}

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
// `expr()` first. The two types stay separate because `Column` also carries a
// name, which `sel`, `Binding` and `Update::set` need and a general expression
// cannot supply.

///|
pub fn[T] Column::raw(self : Column[T]) -> RawExpr {
  self.expr().raw()
}

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
