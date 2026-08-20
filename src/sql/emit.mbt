///|
/// A statement that cannot be written as valid SQL.
///
/// Every `to_sql` shares this: the failures are about the statement being
/// malformed, not about anything the database said.
pub(all) suberror StatementError {
  /// An INSERT was built with no rows, which has no valid SQL form.
  EmptyInsert(table~ : String)
  /// A row supplied a different number of values than the binding has columns.
  ArityMismatch(table~ : String, expected~ : Int, got~ : Int)
  /// An UPDATE was built without any assignment.
  EmptyUpdate(table~ : String)
  /// Two tables in one query claim the same alias, so column references in the
  /// generated SQL would be ambiguous. Self-joins need distinct aliases, which
  /// aya cannot yet assign (see `Table` docs).
  DuplicateAlias(tbl~ : String)
} derive(Debug)

///|
/// Renders expressions to SQL text while collecting their literals.
///
/// Rendering and parameter collection are deliberately one pass: a literal
/// becomes a placeholder at the moment its text is written, so the parameter
/// list can never fall out of step with the placeholders that consume it.
pub struct Emitter {
  dialect : Dialect
  params : Array[SqlValue]
}

///|
pub fn Emitter::new(dialect : Dialect) -> Emitter {
  { dialect, params: [] }
}

///|
/// Bind one value and hand back the placeholder that stands for it.
fn Emitter::param(self : Emitter, v : SqlValue) -> String {
  self.params.push(v)
  match self.dialect {
    Sqlite => "?"
    Postgres => "$\{self.params.length()}"
  }
}

///|
/// SQL operator precedence. Higher number means tighter binding.
fn prec(op : BinOp) -> Int {
  match op {
    BinOp::Or => 1
    BinOp::And => 2
    _ => ATOM // = <> < > <= >= IS IN LIKE
  }
}

///|
/// The precedence everything that is not `AND` or `OR` sits at.
const ATOM = 4

///|
/// Bracket a rendered expression when it binds more loosely than its context.
fn bracket(s : String, own~ : Int, parent~ : Int) -> String {
  if own < parent {
    "(" + s + ")"
  } else {
    s
  }
}

///|
/// Render an expression, adding brackets only where precedence demands them.
pub fn Emitter::expr(self : Emitter, e : RawExpr, parent? : Int = 0) -> String {
  match e {
    Col(tbl~, name~) => "\{tbl}.\"\{name}\""
    Lit(v) => self.param(v)
    Bin(op, l, r) => {
      let own = prec(op)
      // Left before right: interpolation evaluates in order, and so must the
      // parameters the two sides bind.
      let l = self.expr(l, parent=own)
      let r = self.expr(r, parent=own)
      bracket("\{l} \{op} \{r}", own~, parent~)
    }
    Unary(op, x) =>
      bracket("\{self.expr(x, parent=ATOM)} \{op}", own=ATOM, parent~)
    InList(x, vs) => {
      let x = self.expr(x, parent=ATOM)
      "\{x} IN (\{vs.map(v => self.param(v)).join(", ")})"
    }
    Agg(f, None) => "\{f}(*)"
    Agg(f, Some(x)) => "\{f}(\{self.expr(x)})"
  }
}

///|
/// Render `WHERE a AND b`, or nothing at all when there is no predicate.
///
/// SELECT, UPDATE and DELETE all end this way and differ only in how far the
/// keyword is inset: `indent` precedes `WHERE`, and each further condition
/// lines up two columns beyond it.
fn Emitter::where_clause(
  self : Emitter,
  wheres : Array[RawExpr],
  indent~ : String,
) -> String {
  guard wheres.length() > 0 else { "" }
  let conditions = wheres.map(w => self.expr(w))
  "\n\{indent}WHERE " + conditions.join("\n\{indent}  AND ")
}
