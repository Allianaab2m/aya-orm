///|
/// A driver that records what it was asked to run and replays canned results.
///
/// It exercises aya's own layer — SQL text, parameter order, decoding,
/// transaction bracketing — without pulling in a real database. It is not a
/// SQL engine and does not pretend to be one, so the results it hands back are
/// whatever the test supplied, in the order the test supplied them.
///
/// The same reasoning applies outside aya: a repository written against
/// `@aya.Driver` can be tested against this rather than against a database.
pub struct FakeDb {
  /// What the driver was asked to do, in order.
  log : Array[String]
  /// The statements themselves, with their bound parameters.
  stmts : Array[(String, Array[@aya.SqlValue])]
  /// Result sets returned by successive `query` calls.
  mut results : Array[Array[Array[@aya.SqlValue]]]
  /// Row counts returned by successive `execute` calls.
  mut counts : Array[Int]
  /// How many statements to let through before failing, and with what.
  mut fail_in : Int?
  mut fail_message : String
  /// Which placeholder syntax the recorded SQL is built with.
  dialect : @aya.Dialect
}

///|
/// Build a fake connection.
///
/// `results` feeds `query` and `counts` feeds `execute`, each consumed one
/// entry per call; running past the end yields an empty result set and a row
/// count of zero rather than failing, so a test only has to spell out the
/// statements it cares about.
pub fn FakeDb::new(
  results? : Array[Array[Array[@aya.SqlValue]]] = [],
  counts? : Array[Int] = [],
  dialect? : @aya.Dialect = Sqlite,
) -> FakeDb {
  {
    log: [],
    stmts: [],
    results,
    counts,
    fail_in: None,
    fail_message: "",
    dialect,
  }
}

///|
/// Arm a statement to fail with `message`.
///
/// `after` is how many statements to let through first, so a test can break
/// the second write of a transaction rather than the first and still watch the
/// rollback go out. The failure is one shot: it is consumed by the statement it
/// breaks. `begin`, `commit` and `rollback` are not statements and are neither
/// counted nor failed — a rollback that could itself fail would drown out the
/// error under test.
pub fn FakeDb::fail(self : FakeDb, message : String, after? : Int = 0) -> Unit {
  self.fail_in = Some(after)
  self.fail_message = message
}

///|
/// Consume a pending failure, if one was armed.
fn FakeDb::check(self : FakeDb, sql : String) -> Unit raise @aya.DbError {
  match self.fail_in {
    None => ()
    Some(0) => {
      self.fail_in = None
      raise @aya.QueryFailed(sql~, message=self.fail_message)
    }
    Some(n) => self.fail_in = Some(n - 1)
  }
}

///|
/// Collapse a statement onto one line so the log stays readable.
fn one_line(sql : String) -> String {
  let parts = sql.split("\n").map(s => s.trim().to_owned()).to_array()
  let buf = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      buf.write_string(" ")
    }
    buf.write_string(p)
  }
  buf.to_string()
}

///|
pub impl @aya.Executor for FakeDb with fn query(self, sql, params, columns~) {
  ignore(columns)
  self.check(sql)
  self.log.push("QUERY")
  self.stmts.push((one_line(sql), params))
  if self.results.is_empty() {
    []
  } else {
    let head = self.results[0]
    self.results = self.results[1:].to_owned()
    head
  }
}

///|
pub impl @aya.Executor for FakeDb with fn execute(self, sql, params) {
  self.check(sql)
  self.log.push("EXEC")
  self.stmts.push((one_line(sql), params))
  if self.counts.is_empty() {
    0
  } else {
    let head = self.counts[0]
    self.counts = self.counts[1:].to_owned()
    head
  }
}

///|
pub impl @aya.Executor for FakeDb with fn dialect(self) {
  self.dialect
}

///|
pub impl @aya.Driver for FakeDb with fn begin(self) {
  self.log.push("BEGIN")
}

///|
pub impl @aya.Driver for FakeDb with fn commit(self) {
  self.log.push("COMMIT")
}

///|
pub impl @aya.Driver for FakeDb with fn rollback(self) {
  self.log.push("ROLLBACK")
}
