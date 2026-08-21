///|
/// Failures that come from the database rather than from aya.
pub(all) suberror DbError {
  /// The driver could not talk to the database at all.
  ConnectionFailed(String)
  /// The database rejected or failed a statement.
  QueryFailed(sql~ : String, message~ : String)
  /// `one` found no row where exactly one was required.
  NotFound(sql~ : String)
  /// `one` found more than one row.
  TooManyRows(sql~ : String, got~ : Int)
  /// A nested transaction failed and the enclosing body carried on anyway.
  /// The outermost scope rolled back rather than commit half the work, and
  /// reports the failure that made it impossible.
  RollbackOnly(cause~ : Error)
} derive(Debug)

///|
/// What running a statement needs: text, parameters, and the dialect they were
/// built for. No transaction control.
///
/// This is deliberately the smaller half of what a database connection can do.
/// Everything aya hands to the body of a transaction is an `Executor` and
/// nothing more, so a repository holding one cannot commit or roll back the
/// transaction it is running inside.
pub(open) trait Executor {
  /// Run a statement and return its rows, each already in projection order.
  ///
  /// `columns` is how many values a row must come back with. A driver whose
  /// binding reports the result width can ignore it; one whose binding does
  /// not — SQLite's — needs telling where the row ends.
  async fn query(Self, String, Array[SqlValue], columns~ : Int) -> Array[
    Array[SqlValue],
  ] raise DbError
  /// Run a statement and return how many rows it touched.
  async fn execute(Self, String, Array[SqlValue]) -> Int raise DbError
  /// Which placeholder syntax this executor expects.
  fn dialect(Self) -> Dialect
}

///|
/// What aya needs from a database binding: an `Executor` that can also
/// bracket a transaction.
///
/// Everything above this trait is dialect-agnostic: aya builds SQL text and
/// an ordered parameter list, and a driver is whatever can run that pair. A
/// driver is also the connection — pooling, if wanted, belongs outside.
///
/// The three transaction statements are separated out from `Executor` because
/// they are a capability, not a detail: `Tx` is the only thing in aya that
/// sends them, and nothing aya hands to user code implements this trait.
pub(open) trait Driver: Executor {
  async fn begin(Self) -> Unit raise DbError
  async fn commit(Self) -> Unit raise DbError
  async fn rollback(Self) -> Unit raise DbError
}

///|
/// A driver plus how deep into nested transactions it currently is.
///
/// Build one per connection, at wiring time, and hand *it* to every repository
/// rather than handing them the driver. That shared depth is the whole point:
/// a repository that opens a transaction of its own joins the enclosing one
/// instead of asking the database to `BEGIN` twice.
///
/// ```moonbit nocheck
/// let db = @aya.Tx::new(driver)
/// let tickets = SqlTickets::new(db)
/// let users = SqlUsers::new(db)
/// @aya.transaction(db, _ => {
///   tickets.save(a) // both saves land in one transaction
///   users.save(b)
/// })
/// ```
///
/// A `Tx` is not safe to share between concurrently running tasks: the depth
/// it counts is a property of one connection's position in one call stack.
pub struct Tx[D] {
  db : D
  /// How many `transaction` scopes are currently open. Zero means no
  /// transaction is in flight and the next one has to `BEGIN`.
  mut depth : Int
  /// What a nested scope failed with, if one did. Set once and only cleared
  /// when the outermost scope finishes, so the first failure is the one
  /// reported.
  mut failure : Error?
}

///|
/// Wrap a driver so transactions over it can nest.
pub fn[D] Tx::new(db : D) -> Tx[D] {
  { db, depth: 0, failure: None }
}

///|
/// The driver underneath, for the things aya does not model.
///
/// Reaching for this inside a `transaction` body means talking to the same
/// connection the transaction is open on, which is usually what is wanted —
/// and also means `commit` and `rollback` are in reach again, which is not.
pub fn[D] Tx::driver(self : Tx[D]) -> D {
  self.db
}

///|
/// Whether a transaction is currently open on this connection.
pub fn[D] Tx::is_open(self : Tx[D]) -> Bool {
  self.depth > 0
}

///|
pub impl[D : Driver] Executor for Tx[D] with fn query(
  self,
  sql,
  params,
  columns~,
) {
  Executor::query(self.db, sql, params, columns~)
}

///|
pub impl[D : Driver] Executor for Tx[D] with fn execute(self, sql, params) {
  Executor::execute(self.db, sql, params)
}

///|
pub impl[D : Driver] Executor for Tx[D] with fn dialect(self) {
  Executor::dialect(self.db)
}

///|
/// Run `body` inside a transaction, committing on success and rolling back on
/// any failure.
///
/// Written as a combinator rather than exposed as begin/commit/rollback so
/// that an early `raise` in the middle of `body` cannot leave a transaction
/// open. MoonBit's error effect does the work a transaction monad would do
/// elsewhere: `body` is an ordinary function that may raise.
///
/// Calls nest. Only the outermost scope sends `BEGIN` and `COMMIT`; an inner
/// one just runs its body, so `A.save()` and `B.save()` land in one
/// transaction when something wrapped them in another. What an inner scope
/// cannot do is fail by itself: with no savepoint there is no way to undo only
/// its writes, so its failure marks the whole transaction rollback-only and
/// the outermost scope raises `RollbackOnly` rather than commit half the work.
pub async fn[D : Driver, A] transaction(
  tx : Tx[D],
  body : async (Tx[D]) -> A,
) -> A {
  if tx.depth > 0 {
    tx.join(body)
  } else {
    tx.outermost(body)
  }
}

///|
/// Run `body` as part of the transaction that is already open.
///
/// No statement goes out either side of it. The depth is still counted, so a
/// scope nested three deep knows it is not the one that has to commit.
async fn[D, A] Tx::join(self : Tx[D], body : async (Tx[D]) -> A) -> A {
  self.depth += 1
  try body(self) catch {
    e => {
      self.depth -= 1
      // Keep the first failure: it is the one that made the transaction
      // uncommittable, whatever happened after it.
      if self.failure is None {
        self.failure = Some(e)
      }
      raise e
    }
  } noraise {
    result => {
      self.depth -= 1
      result
    }
  }
}

///|
/// Open a transaction, run `body`, and close it exactly once.
async fn[D : Driver, A] Tx::outermost(
  self : Tx[D],
  body : async (Tx[D]) -> A,
) -> A {
  Driver::begin(self.db)
  self.depth = 1
  self.failure = None
  try body(self) catch {
    e => {
      self.finish() |> ignore
      self.rollback_quietly()
      raise e
    }
  } noraise {
    // Deciding here rather than in the `catch` arm is what keeps the two
    // outcomes apart: a `raise` from this arm is not caught by the arm above,
    // so nothing can roll back twice.
    result =>
      match self.finish() {
        // The body swallowed a nested scope's failure and returned anyway.
        // Committing now would write whichever half of the work survived.
        Some(cause) => {
          self.rollback_quietly()
          raise RollbackOnly(cause~)
        }
        None =>
          try {
            Driver::commit(self.db)
            result
          } catch {
            e => {
              self.rollback_quietly()
              raise e
            }
          }
      }
  }
}

///|
/// Close the outermost scope, handing back whatever poisoned it, if anything.
fn[D] Tx::finish(self : Tx[D]) -> Error? {
  self.depth = 0
  let failure = self.failure
  self.failure = None
  failure
}

///|
/// Roll back, ignoring a failure to do so.
///
/// A failed rollback must not replace the error that caused it: the original
/// failure is the one worth reporting.
async fn[D : Driver] Tx::rollback_quietly(self : Tx[D]) -> Unit {
  Driver::rollback(self.db) catch {
    _ => ()
  }
}

///|
/// Build the statement for this executor and run it.
///
/// The text comes back alongside the rows because `one` names the statement in
/// the error it raises.
async fn[E : Executor, C, A] Query::fetch(
  self : Query[C, A],
  db : E,
) -> (String, Array[Array[SqlValue]]) {
  let (sql, params) = self.to_sql(dialect=Executor::dialect(db))
  let rows = Executor::query(db, sql, params, columns=self.projection.length())
  (sql, rows)
}

///|
/// Run the query and decode every row.
pub async fn[E : Executor, C, A] Query::run(
  self : Query[C, A],
  db : E,
) -> Array[A] {
  let (_, rows) = self.fetch(db)
  rows.map(row => (self.decode)(row[:]))
}

///|
/// Run the query and decode the single row it must return.
pub async fn[E : Executor, C, A] Query::one(self : Query[C, A], db : E) -> A {
  let (sql, rows) = self.fetch(db)
  match rows {
    [] => raise NotFound(sql~)
    [row] => (self.decode)(row[:])
    _ => raise TooManyRows(sql~, got=rows.length())
  }
}

///|
/// Run the query and decode the first row, if there is one.
pub async fn[E : Executor, C, A] Query::first(self : Query[C, A], db : E) -> A? {
  let (_, rows) = self.fetch(db)
  match rows {
    [] => None
    [row, ..] => Some((self.decode)(row[:]))
  }
}

///|
/// Run the insert, returning how many rows were added.
pub async fn[E : Executor] Insert::run(self : Insert, db : E) -> Int {
  let (sql, params) = self.to_sql(dialect=Executor::dialect(db))
  Executor::execute(db, sql, params)
}

///|
/// Run the update, returning how many rows were changed.
pub async fn[E : Executor, C] Update::run(self : Update[C], db : E) -> Int {
  let (sql, params) = self.to_sql(dialect=Executor::dialect(db))
  Executor::execute(db, sql, params)
}

///|
/// Run the delete, returning how many rows were removed.
pub async fn[E : Executor, C] Delete::run(self : Delete[C], db : E) -> Int {
  let (sql, params) = self.to_sql(dialect=Executor::dialect(db))
  Executor::execute(db, sql, params)
}
