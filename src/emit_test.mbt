///|
fn a() -> Column[Int] {
  Column::new(tbl="t", name="a")
}

///|
fn b() -> Column[Int] {
  Column::new(tbl="t", name="b")
}

///|
fn c() -> Column[Int] {
  Column::new(tbl="t", name="c")
}

///|
fn d() -> Column[Int?] {
  Column::new(tbl="t", name="d")
}

///|
fn render(e : Expr[Bool]) -> String {
  Emitter::new(Dialect::Sqlite).expr(e.raw())
}

///|
test "precedence: OR inside AND needs parens" {
  inspect(
    render((a().expr().eq(1) | b().expr().eq(2)) & c().expr().eq(3)),
    content=(
      #|(t."a" = ? OR t."b" = ?) AND t."c" = ?
    ),
  )
}

///|
test "precedence: AND inside OR needs none" {
  inspect(
    render((a().expr().eq(1) & b().expr().eq(2)) | c().expr().eq(3)),
    content=(
      #|t."a" = ? AND t."b" = ? OR t."c" = ?
    ),
  )
}

///|
test "precedence: nested OR in the middle" {
  inspect(
    render(
      a().expr().eq(1) &
      (b().expr().eq(2) | c().expr().eq(3)) &
      d().expr().is_some(),
    ),
    content=(
      #|t."a" = ? AND (t."b" = ? OR t."c" = ?) AND t."d" IS NOT NULL
    ),
  )
}

///|
test "precedence: same operator chains without parens" {
  inspect(
    render(a().expr().eq(1) & b().expr().eq(2) & c().expr().eq(3)),
    content=(
      #|t."a" = ? AND t."b" = ? AND t."c" = ?
    ),
  )
}

///|
test "precedence: OR on both sides of AND" {
  inspect(
    render(
      (a().expr().eq(1) | b().expr().eq(2)) &
      (c().expr().eq(3) | a().expr().eq(4)),
    ),
    content=(
      #|(t."a" = ? OR t."b" = ?) AND (t."c" = ? OR t."a" = ?)
    ),
  )
}

///|
test "in_ expands one placeholder per element" {
  inspect(
    render(a().expr().in_([1, 2, 3])),
    content=(
      #|t."a" IN (?, ?, ?)
    ),
  )
}

///|
test "postgres numbers its placeholders" {
  let em = Emitter::new(Postgres)
  inspect(
    em.expr((a().expr().eq(1) & b().expr().eq(2)).raw()),
    content=(
      #|t."a" = $1 AND t."b" = $2
    ),
  )
}

///|
test "params are collected in textual order" {
  let em = Emitter::new(Sqlite)
  let _ = em.expr((a().expr().eq(10) & b().expr().eq(20)).raw())
  debug_inspect(em.params, content="[VInt(10), VInt(20)]")
}

///|
test "probe: ast shape" {
  let e = (a().expr().eq(1) | b().expr().eq(2)) & c().expr().eq(3)
  debug_inspect(
    e.raw(),
    content=(
      #|Bin(
      #|  And,
      #|  Bin(
      #|    Or,
      #|    Bin(Eq, Col(tbl="t", name="a"), Lit(VInt(1))),
      #|    Bin(Eq, Col(tbl="t", name="b"), Lit(VInt(2))),
      #|  ),
      #|  Bin(Eq, Col(tbl="t", name="c"), Lit(VInt(3))),
      #|)
    ),
  )
}
