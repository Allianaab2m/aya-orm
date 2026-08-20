///|
/// A cairn connection backed by `moonbit-community/sqlite3`.
///
/// That binding is deliberately thin: it hands back whatever you ask a column
/// for and has no public way to report a column's type or to say `NULL`. Both
/// gaps are closed here rather than worked around, because the alternative in
/// each case is a wrong answer rather than an error.
///
/// Reading, the driver declares `RowShape::Typed`, so cairn writes the SELECT
/// list as `typeof(e), e` pairs and SQLite itself names the storage class of
/// every value. Writing, a `VNull` parameter is simply not bound: SQLite reads
/// an unbound parameter as NULL, which is the one way to send one through this
/// binding.
pub struct Sqlite {
  conn : @sqlite3.Connection
}

///|
/// Open a database file, or `":memory:"` for one that lives as long as the
/// connection.
pub fn Sqlite::open(path : String) -> Sqlite raise @sql.DbError {
  { conn: @sqlite3.Connection::open(path) } catch {
    e => raise @sql.ConnectionFailed("cannot open \{path}: \{describe_code(e)}")
  }
}

///|
/// Close the connection, releasing the database handle.
pub fn Sqlite::close(self : Sqlite) -> Unit raise @sql.DbError {
  self.conn.close() catch {
    e => raise @sql.ConnectionFailed(self.describe(e))
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
/// The underlying connection, for the things cairn does not model.
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
pub impl @sql.Executor for Sqlite with fn dialect(_self) {
  @sql.Dialect::Sqlite
}

///|
/// The binding reports neither a column's type nor its nullness, so cairn is
/// asked to write the SELECT list with both alongside each value.
pub impl @sql.Executor for Sqlite with fn row_shape(_self) {
  @sql.RowShape::Typed
}

///|
pub impl @sql.Executor for Sqlite with fn query(self, sql, params, columns~) {
  let stmt = self.prepare(sql)
  // The statement holds native memory that dropping it will not release, and a
  // failure to release it must not displace the error that got us here.
  defer self.discard(stmt)
  self.bind_all(stmt, params, sql)
  let rows = []
  while (stmt.step() catch {
          e => raise @sql.QueryFailed(sql~, message=self.describe(e))
        }) {
    let row = []
    for i in 0..<columns {
      row.push(self.cell(stmt, i, sql))
    }
    rows.push(row)
  }
  rows
}

///|
pub impl @sql.Executor for Sqlite with fn execute(self, sql, params) {
  let stmt = self.prepare(sql)
  defer self.discard(stmt)
  self.bind_all(stmt, params, sql)
  stmt.step_once() catch {
    e => raise @sql.QueryFailed(sql~, message=self.describe(e))
  }
  self.changes(sql)
}

///|
pub impl @sql.Driver for Sqlite with fn begin(self) {
  self.command("BEGIN")
}

///|
pub impl @sql.Driver for Sqlite with fn commit(self) {
  self.command("COMMIT")
}

///|
pub impl @sql.Driver for Sqlite with fn rollback(self) {
  self.command("ROLLBACK")
}

///|
/// Fold one `typeof(e), e` pair back into the value it describes.
///
/// The tag is SQLite's storage class, which is a property of the value rather
/// than of the column: a column declared `INTEGER` can hold text, and does if
/// something put text in it. Reading the tag rather than the declared type is
/// what makes the answer match what is actually stored.
fn Sqlite::cell(
  _self : Sqlite,
  stmt : @sqlite3.Statement,
  index : Int,
  sql : String,
) -> @sql.SqlValue raise @sql.DbError {
  let tag : String = stmt.column(index=index * 2)
  let at = index * 2 + 1
  match tag {
    "null" => VNull
    "integer" => {
      let n : Int64 = stmt.column(index=at)
      VInt(n)
    }
    "real" => {
      let d : Double = stmt.column(index=at)
      VDouble(d)
    }
    "text" => {
      let s : String = stmt.column(index=at)
      VText(s)
    }
    "blob" => {
      let b : Bytes = stmt.column(index=at)
      VBytes(b)
    }
    other =>
      raise @sql.QueryFailed(
        sql~,
        message="column \{index} reported the unknown SQLite storage class \"\{other}\"",
      )
  }
}

///|
/// Bind the parameter list, one-based, the way SQLite counts.
fn Sqlite::bind_all(
  self : Sqlite,
  stmt : @sqlite3.Statement,
  params : Array[@sql.SqlValue],
  sql : String,
) -> Unit raise @sql.DbError {
  for i, v in params {
    bind_one(stmt, i + 1, v) catch {
      e => raise @sql.QueryFailed(sql~, message=self.describe(e))
    }
  }
}

///|
fn bind_one(
  stmt : @sqlite3.Statement,
  index : Int,
  v : @sql.SqlValue,
) -> Unit raise @sqlite3.SqliteError {
  match v {
    // Left unbound on purpose: SQLite reads an unbound parameter as NULL, and
    // the binding exposes no way to say so directly.
    VNull => ()
    VInt(n) => stmt.bind(index~, n)
    VDouble(d) => stmt.bind(index~, d)
    VText(s) => stmt.bind(index~, s)
    // SQLite has no boolean type; it stores 0 and 1, and reads them back as
    // `VInt`, which `SqlDecode for Bool` already accepts.
    VBool(b) => stmt.bind(index~, if b { 1 } else { 0 })
    VBytes(b) => stmt.bind(index~, b)
  }
}

///|
/// How many rows the last write touched.
///
/// The binding does not expose `sqlite3_changes`, but SQLite answers the same
/// question in SQL, and asking it on the same connection is what makes the
/// answer the right one.
fn Sqlite::changes(self : Sqlite, sql : String) -> Int raise @sql.DbError {
  let stmt = self.prepare("SELECT changes()")
  defer self.discard(stmt)
  let has_row = stmt.step() catch {
    e => raise @sql.QueryFailed(sql~, message=self.describe(e))
  }
  if !has_row {
    raise @sql.QueryFailed(sql~, message="SELECT changes() returned no row")
  }
  stmt.column(index=0)
}

///|
/// Run a statement that takes no parameters and returns no rows.
fn Sqlite::command(self : Sqlite, sql : String) -> Unit raise @sql.DbError {
  let stmt = self.prepare(sql)
  defer self.discard(stmt)
  stmt.step_once() catch {
    e => raise @sql.QueryFailed(sql~, message=self.describe(e))
  }
}

///|
fn Sqlite::prepare(
  self : Sqlite,
  sql : String,
) -> @sqlite3.Statement raise @sql.DbError {
  self.conn.prepare(sql) catch {
    e => raise @sql.QueryFailed(sql~, message=self.describe(e))
  }
}

///|
/// Release a statement, ignoring a failure to do so.
///
/// `sqlite3_finalize` reports the most recent evaluation's error, so on the
/// failing path it would only restate the error already being raised, and on
/// the succeeding path there is nothing to report.
fn Sqlite::discard(self : Sqlite, stmt : @sqlite3.Statement) -> Unit {
  ignore(self)
  stmt.finalize() catch {
    _ => ()
  }
}

///|
/// A SQLite failure, as a result code plus whatever the connection has to say
/// about it.
fn Sqlite::describe(self : Sqlite, e : Error) -> String {
  let message = self.conn.get_errmsg()
  if message.is_empty() {
    describe_code(e)
  } else {
    "\{message} (\{describe_code(e)})"
  }
}

///|
/// The result code on its own, for when there is no connection to ask.
fn describe_code(e : Error) -> String {
  match e {
    @sqlite3.SqliteError((code, _)) => "SQLite error \{code}"
    other => "\{other}"
  }
}
