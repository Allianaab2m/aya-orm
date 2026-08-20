///|
/// A aya connection backed by `moonbit-community/postgres`.
///
/// Everything aya asks of a driver — run this text with these parameters,
/// tell me your placeholder syntax, bracket a transaction — the client already
/// does. What this adds is the two translations either side of it: aya's
/// `SqlValue` to and from PostgreSQL's typed wire, and the client's error
/// vocabulary into aya's.
pub struct Postgres {
  client : @client.Client
}

///|
/// Wrap an already-connected client.
///
/// Useful when the client comes from somewhere else — a pool, or a connection
/// the caller is also using directly. `with_connection` is the shorter path
/// when aya is the only user.
pub fn Postgres::new(client : @client.Client) -> Postgres {
  { client, }
}

///|
/// The underlying client, for the things aya does not model.
pub fn Postgres::client(self : Postgres) -> @client.Client {
  self.client
}

///|
/// A connection configuration with aya's defaults filled in.
///
/// The client's own `Config::new` asks for an application name and a database
/// up front; both have obvious defaults here, and spelling them out at every
/// call site only obscures the two fields that actually vary.
pub fn config(
  host~ : String,
  user~ : String,
  database? : String = "",
  password? : String,
  port? : Int = 5432,
  ssl_mode? : @client.SslMode,
  application_name? : String = "aya",
) -> @client.Config {
  @client.Config::new(
    host,
    port~,
    user~,
    database=if database.is_empty() { user } else { database },
    password?,
    ssl_mode?,
    application_name~,
  )
}

///|
/// Connect, run `body` against the connection, and close it again.
///
/// The client splits a connection in two: a `Client` that statements are sent
/// through, and a `Connection` whose `run` drives the protocol underneath it.
/// Nothing happens unless something is driving that pump, so it is spawned
/// here rather than left as a step for the caller to remember. Scoping the
/// whole thing to `body` is what makes the close unconditional: the connection
/// is shut regardless of how `body` ends.
pub async fn[A] with_connection(
  config : @client.Config,
  body : async (Postgres) -> A,
) -> A {
  @async.with_task_group(group => {
    let (client, connection) = @client.connect(config) catch {
      e => raise as_db_error("", e)
    }
    // `no_wait`: the pump has no end of its own, so the group must not sit
    // waiting for it once `body` has returned.
    group.spawn_bg(() => connection.run(), no_wait=true)
    group.add_defer(() => client.close())
    body(Postgres::new(client))
  })
}

///|
pub impl @aya.Executor for Postgres with fn query(
  self,
  sql,
  parameters,
  columns~,
) {
  // The row description already says how wide a row is, so the hint aya
  // passes for bindings that cannot say is not needed here.
  ignore(columns)
  let rows = self.client.query(sql, params=params(parameters)).collect() catch {
      e => raise as_db_error(sql, e)
    }
  rows.map(row => {
    let out = []
    for i in 0..<row.len() {
      out.push(cell(row, i, sql))
    }
    out
  })
}

///|
pub impl @aya.Executor for Postgres with fn execute(self, sql, parameters) {
  self.client.execute(sql, params=params(parameters)) catch {
    e => raise as_db_error(sql, e)
  }
}

///|
pub impl @aya.Executor for Postgres with fn dialect(_self) {
  @aya.Dialect::Postgres
}

///|
/// Transactions go out as plain statements rather than through the client's
/// own `Transaction` handle.
///
/// The handle is the better API in general — it is a value you cannot forget to
/// finish — but aya's `transaction` combinator already provides that
/// guarantee one level up, and its `Driver` contract is three independent
/// calls. Sending the statements keeps the driver a translation layer instead
/// of making it hold transaction state of its own.
pub impl @aya.Driver for Postgres with fn begin(self) {
  self.command("BEGIN")
}

///|
pub impl @aya.Driver for Postgres with fn commit(self) {
  self.command("COMMIT")
}

///|
pub impl @aya.Driver for Postgres with fn rollback(self) {
  self.command("ROLLBACK")
}

///|
async fn Postgres::command(
  self : Postgres,
  sql : String,
) -> Unit raise @aya.DbError {
  self.client.batch_execute(sql) catch {
    e => raise as_db_error(sql, e)
  }
}
