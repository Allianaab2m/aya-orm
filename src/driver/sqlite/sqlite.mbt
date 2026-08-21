///|
/// A aya connection backed by `moonbit-community/sqlite3`.
///
/// The binding is thin but no longer lossy: `@sqlite3.Value` carries SQLite's
/// storage class in both directions, so a column reports what is actually
/// stored in it and a `VNull` parameter goes out as a bound NULL. That is the
/// whole of the translation — everything else here is resource handling and
/// turning a `SqliteError` into aya's own.
pub struct Sqlite {
  conn : @sqlite3.Connection
}

///|
/// Open a database file, or `":memory:"` for one that lives as long as the
/// connection.
pub fn Sqlite::open(path : String) -> Sqlite raise @aya.DbError {
  { conn: @sqlite3.Connection::open(path) } catch {
    e => raise @aya.ConnectionFailed("cannot open \{path}: \{describe(e)}")
  }
}

///|
/// Close the connection, releasing the database handle.
pub fn Sqlite::close(self : Sqlite) -> Unit raise @aya.DbError {
  self.conn.close() catch {
    e => raise @aya.ConnectionFailed(describe(e))
  }
}

///|
/// Close the connection, ignoring a failure to do so.
fn Sqlite::close_quietly(self : Sqlite) -> Unit {
  self.close() catch {
    _ => ()
  }
}

///|
/// The underlying connection, for the things aya does not model.
pub fn Sqlite::connection(self : Sqlite) -> @sqlite3.Connection {
  self.conn
}

///|
/// Open a database, run `body` against it, and close it again.
///
/// The binding manages its resources by hand — a connection that is not closed
/// stays open — so scoping it to `body` is what makes the close unconditional.
pub async fn[A] with_connection(path : String, body : async (Sqlite) -> A) -> A {
  let db = Sqlite::open(path)
  // A failure to close cannot be reported from here without displacing
  // whatever `body` raised, and that is the more useful of the two — which is
  // also why `defer` will not take a raising call at all.
  defer db.close_quietly()
  body(db)
}

///|
pub impl @aya.Executor for Sqlite with fn dialect(_self) {
  @aya.Dialect::Sqlite
}

///|
pub impl @aya.Executor for Sqlite with fn query(self, sql, params, columns~) {
  let stmt = self.prepare(sql)
  // The statement holds native memory that dropping it will not release, and a
  // failure to release it must not displace the error that got us here.
  defer discard(stmt)
  bind_all(stmt, params, sql)
  let rows = []
  while (stmt.step() catch {
          e => raise @aya.QueryFailed(sql~, message=describe(e))
        }) {
    let row = []
    // The binding does not report how wide a result row is, so aya's count of
    // the projection is what says where the row ends.
    for i in 0..<columns {
      row.push(cell(stmt, i, sql))
    }
    rows.push(row)
  }
  rows
}

///|
pub impl @aya.Executor for Sqlite with fn execute(self, sql, params) {
  let stmt = self.prepare(sql)
  defer discard(stmt)
  bind_all(stmt, params, sql)
  run_once(stmt, sql)
  self.changes(sql)
}

///|
pub impl @aya.Driver for Sqlite with fn begin(self) {
  self.command("BEGIN")
}

///|
pub impl @aya.Driver for Sqlite with fn commit(self) {
  self.command("COMMIT")
}

///|
pub impl @aya.Driver for Sqlite with fn rollback(self) {
  self.command("ROLLBACK")
}

///|
/// Read one column as the value SQLite actually holds there.
///
/// The class the binding reports is a property of the value rather than of the
/// column: a column declared `INTEGER` can hold text, and does if something put
/// text in it. Reading the value's class rather than the column's declared type
/// is what makes the answer match what is stored.
fn cell(
  stmt : @sqlite3.Statement,
  index : Int,
  sql : String,
) -> @aya.SqlValue raise @aya.DbError {
  let value : @sqlite3.Value = stmt.column(index~) catch {
    e => raise @aya.QueryFailed(sql~, message=describe(e))
  }
  match value {
    Null => VNull
    Integer(n) => VInt(n)
    Real(d) => VDouble(d)
    Text(s) => VText(s)
    Blob(b) => VBytes(b)
  }
}

///|
/// Bind the parameter list, one-based, the way SQLite counts.
fn bind_all(
  stmt : @sqlite3.Statement,
  params : Array[@aya.SqlValue],
  sql : String,
) -> Unit raise @aya.DbError {
  for i, v in params {
    stmt.bind(index=i + 1, storage_class(v)) catch {
      e => raise @aya.QueryFailed(sql~, message=describe(e))
    }
  }
}

///|
/// An aya value as the SQLite storage class it belongs in.
fn storage_class(v : @aya.SqlValue) -> @sqlite3.Value {
  match v {
    VNull => Null
    VInt(n) => Integer(n)
    VDouble(d) => Real(d)
    VText(s) => Text(s)
    // SQLite has no boolean type; it stores 0 and 1, and reads them back as
    // `VInt`, which `SqlDecode for Bool` already accepts.
    VBool(b) => Integer(if b { 1 } else { 0 })
    VBytes(b) => Blob(b)
  }
}

///|
/// How many rows the last write touched.
///
/// The binding does not expose `sqlite3_changes`, but SQLite answers the same
/// question in SQL, and asking it on the same connection is what makes the
/// answer the right one.
fn Sqlite::changes(self : Sqlite, sql : String) -> Int raise @aya.DbError {
  let stmt = self.prepare("SELECT changes()")
  defer discard(stmt)
  let has_row = stmt.step() catch {
    e => raise @aya.QueryFailed(sql~, message=describe(e))
  }
  if !has_row {
    raise @aya.QueryFailed(sql~, message="SELECT changes() returned no row")
  }
  let n : Int64 = stmt.column(index=0) catch {
    e => raise @aya.QueryFailed(sql~, message=describe(e))
  }
  n.to_int()
}

///|
/// Run a statement that takes no parameters and returns no rows.
fn Sqlite::command(self : Sqlite, sql : String) -> Unit raise @aya.DbError {
  let stmt = self.prepare(sql)
  defer discard(stmt)
  run_once(stmt, sql)
}

///|
/// Step a statement that is not supposed to produce rows.
///
/// A row coming back means the statement was a query, which is worth saying
/// out loud: `execute` would otherwise report `changes()` from a SELECT and
/// call it a row count.
fn run_once(stmt : @sqlite3.Statement, sql : String) -> Unit raise @aya.DbError {
  let has_row = stmt.step() catch {
    e => raise @aya.QueryFailed(sql~, message=describe(e))
  }
  if has_row {
    raise @aya.QueryFailed(
      sql~,
      message="a statement run for its effect returned a row",
    )
  }
}

///|
fn Sqlite::prepare(
  self : Sqlite,
  sql : String,
) -> @sqlite3.Statement raise @aya.DbError {
  self.conn.prepare(sql) catch {
    e => raise @aya.QueryFailed(sql~, message=describe(e))
  }
}

///|
/// Release a statement, ignoring a failure to do so.
///
/// `sqlite3_finalize` reports the most recent evaluation's error, so on the
/// failing path it would only restate the error already being raised, and on
/// the succeeding path there is nothing to report.
fn discard(stmt : @sqlite3.Statement) -> Unit {
  stmt.finalize() catch {
    _ => ()
  }
}

///|
/// A SQLite failure, as what SQLite said plus the codes that classify it.
///
/// The binding captures `sqlite3_errmsg` where the call failed and carries it
/// on the error itself, so there is no mutable connection state left to race
/// against by the time this runs.
fn describe(e : Error) -> String {
  match e {
    @sqlite3.SqliteError(code~, extended~, msg~) => {
      let classification = match extended {
        Some(extended) =>
          "code=\{@debug.to_string(code)}, extended=\{@debug.to_string(extended)}"
        None => "code=\{@debug.to_string(code)}"
      }
      "\{msg} (\{classification})"
    }
    other => "\{other}"
  }
}
