///|
pub struct Emitter {
  dialect : Dialect
  params : Array[SqlValue]
}

///|
pub fn Emitter::new(dialect : Dialect) -> Emitter {
  { dialect, params: [] }
}

///|
fn Emitter::param(self : Emitter, v : SqlValue) -> String {
  self.params.push(v)
  match self.dialect {
    Sqlite => "?"
    Postgres => "$\{self.params.length()}"
  }
}

///|
/// SQL operator precedence. Higher number means higher precedence.
fn prec(op : BinOp) -> Int {
  match op {
    BinOp::Or => 1
    BinOp::And => 2
    _ => 4 // = <> < > <= >= IS IN LIKE
  }
}

///|
/// Add brackets if the child expression has lower precedence than the parent.
pub fn Emitter::expr(self : Emitter, e : RawExpr, parent? : Int = 0) -> String {
  match e {
    Col(tbl~, name~) => "\{tbl}.\"\{name}\""
    Lit(v) => self.param(v)
    Bin(op, l, r) => {
      let p = prec(op)
      let s = "\{self.expr(l, parent=p)} \{op} \{self.expr(r, parent=p)}"
      if p < parent {
        "(" + s + ")"
      } else {
        s
      }
    }
    Unary(op, x) => {
      let s = "\{self.expr(x, parent=4)} \{op}"
      if 4 < parent {
        "(" + s + ")"
      } else {
        s
      }
    }
    InList(x, vs) => {
      let ps = vs.map(v => self.param(v))
      "\{self.expr(x, parent=4)} IN (\{join(ps, ", ")})"
    }
    Agg(f, None) => "\{f}(*)"
    Agg(f, Some(x)) => "\{f}(\{self.expr(x)})"
  }
}

///|
pub fn join(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder::new()

  for i, p in parts {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(p)
  }
  buf.to_string()
}

///|
test "probe: prec" {
  debug_inspect(
    (prec(BinOp::And), prec(BinOp::Or), prec(BinOp::Eq)),
    content="(2, 1, 4)",
  )
}
