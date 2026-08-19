///|
/// Failures that come from the database rather than from cairn.
pub(all) suberror DbError {
  /// The driver could not talk to the database at all.
  ConnectionFailed(String)
  /// The database rejected or failed a statement.
  QueryFailed(sql~ : String, message~ : String)
  /// `one` found no row where exactly one was required.
  NotFound(sql~ : String)
  /// `one` found more than one row.
  TooManyRows(sql~ : String, got~ : Int)
} derive(Debug)

///|
/// What cairn needs from a database binding.
///
/// Everything above this trait is dialect-agnostic: cairn builds SQL text and
/// an ordered parameter list, and a driver is whatever can run that pair. A
/// driver is also the connection — pooling, if wanted, belongs outside.
pub(open) trait Driver {
  /// Run a statement and return its rows, each already in projection order.
  fn query(Self, String, Array[SqlValue]) -> Array[Array[SqlValue]] raise DbError
  /// Run a statement and return how many rows it touched.
  fn execute(Self, String, Array[SqlValue]) -> Int raise DbError
  /// Which placeholder syntax this driver expects.
  fn dialect(Self) -> Dialect
  fn begin(Self) -> Unit raise DbError
  fn commit(Self) -> Unit raise DbError
  fn rollback(Self) -> Unit raise DbError
}

///|
/// Run `body` inside a transaction, committing on success and rolling back on
/// any failure.
///
/// Written as a combinator rather than exposed as begin/commit/rollback so
/// that an early `raise` in the middle of `body` cannot leave a transaction
/// open. MoonBit's error effect does the work a transaction monad would do
/// elsewhere: `body` is an ordinary function that may raise.
pub fn[D : Driver, A] transaction(db : D, body : (D) -> A raise) -> A raise {
  db.begin()
  try {
    let result = body(db)
    db.commit()
    result
  } catch {
    e => {
      // A failed rollback must not replace the error that caused it: the
      // original failure is the one worth reporting.
      db.rollback() catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// Run the query and decode every row.
pub fn[D : Driver, C, A] Query::run(
  self : Query[C, A],
  db : D,
) -> Array[A] raise {
  let (sql, params) = self.to_sql(dialect=db.dialect())
  let rows = db.query(sql, params)
  let out = []
  for row in rows {
    out.push((self.decode)(row[:]))
  }
  out
}

///|
/// Run the query and decode the single row it must return.
pub fn[D : Driver, C, A] Query::one(self : Query[C, A], db : D) -> A raise {
  let (sql, params) = self.to_sql(dialect=db.dialect())
  let rows = db.query(sql, params)
  match rows.length() {
    0 => raise NotFound(sql~)
    1 => (self.decode)(rows[0][:])
    n => raise TooManyRows(sql~, got=n)
  }
}

///|
/// Run the query and decode the first row, if there is one.
pub fn[D : Driver, C, A] Query::first(self : Query[C, A], db : D) -> A? raise {
  let (sql, params) = self.to_sql(dialect=db.dialect())
  let rows = db.query(sql, params)
  if rows.is_empty() {
    None
  } else {
    Some((self.decode)(rows[0][:]))
  }
}

///|
/// Run the insert, returning how many rows were added.
pub fn[D : Driver] Insert::run(self : Insert, db : D) -> Int raise {
  let (sql, params) = self.to_sql(dialect=db.dialect())
  db.execute(sql, params)
}

///|
/// Run the update, returning how many rows were changed.
pub fn[D : Driver, C] Update::run(self : Update[C], db : D) -> Int raise {
  let (sql, params) = self.to_sql(dialect=db.dialect())
  db.execute(sql, params)
}

///|
/// Run the delete, returning how many rows were removed.
pub fn[D : Driver, C] Delete::run(self : Delete[C], db : D) -> Int raise {
  let (sql, params) = self.to_sql(dialect=db.dialect())
  db.execute(sql, params)
}
