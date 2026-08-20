///|
fn snap(src : String) -> @ddl.Snapshot raise Error {
  @kit.snapshot_of_sources([("test.mbt", src)], dialect=Sqlite)
}

///|
let accounts : String =
  #|#aya.table(name="accounts", alias="a")
  #|pub struct Account {
  #|  #aya.id
  #|  id : Int
  #|}
  #|

///|
let accounts_with_note : String =
  #|#aya.table(name="accounts", alias="a")
  #|pub struct Account {
  #|  #aya.id
  #|  id : Int
  #|  note : String?
  #|}
  #|

///|
test "an absent config is the default config" {
  debug_inspect(
    @kit.Config::new(),
    content=(
      #|{ dialect: Sqlite, schema: ["src"], out: "migrations" }
    ),
  )
}

///|
test "every config key is optional" {
  debug_inspect(
    @kit.Config::from_json_string("{ \"schema\": \"src/example\" }"),
    content=(
      #|{ dialect: Sqlite, schema: ["src/example"], out: "migrations" }
    ),
  )
  debug_inspect(
    @kit.Config::from_json_string(
      "{ \"dialect\": \"postgres\", \"schema\": [\"a\", \"b\"], \"out\": \"db\" }",
    ),
    content=(
      #|{ dialect: Postgres, schema: ["a", "b"], out: "db" }
    ),
  )
}

///|
test "a config round trips through its file" {
  let config = @kit.Config::{
    dialect: Sqlite,
    schema: ["src/example"],
    out: "migrations",
  }
  let text = config.to_json_string()
  inspect(
    text,
    content=(
      #|{
      #|  "dialect": "sqlite",
      #|  "schema": [
      #|    "src/example"
      #|  ],
      #|  "out": "migrations"
      #|}
      #|
    ),
  )
  assert_eq(@kit.Config::from_json_string(text), config)
}

///|
test "an unreadable config says what is wrong with it" {
  try {
    let _ = @kit.Config::from_json_string("{ \"dialect\": \"mysql\" }")
    fail("expected BadConfig")
  } catch {
    e =>
      inspect(
        e,
        content="aya.json: dialect `mysql`: known dialects are `sqlite` and `postgres`",
      )
  }
}

///|
test "a journal round trips through its file" {
  let journal = @kit.Journal::{
    version: "1",
    dialect: Sqlite,
    entries: [
      { idx: 0, tag: "0000_create_table_accounts", when_: 1, breakpoints: true },
      {
        idx: 1,
        tag: "0001_add_column_accounts_note",
        when_: 2,
        breakpoints: true,
      },
    ],
  }
  let text = journal.to_json_string()
  inspect(
    text,
    content=(
      #|{
      #|  "version": "1",
      #|  "dialect": "sqlite",
      #|  "entries": [
      #|    { "idx": 0, "tag": "0000_create_table_accounts", "when": 1, "breakpoints": true },
      #|    { "idx": 1, "tag": "0001_add_column_accounts_note", "when": 2, "breakpoints": true }
      #|  ]
      #|}
      #|
    ),
  )
  assert_eq(@kit.Journal::from_json_string(text), journal)
}

///|
test "an empty journal is a legal one" {
  let journal = @kit.Journal::new(Sqlite)
  assert_eq(journal.next_index(), 0)
  assert_eq(@kit.Journal::from_json_string(journal.to_json_string()), journal)
}

///|
test "planning nothing writes nothing" {
  let plan = @kit.plan(
    journal=@kit.Journal::new(Sqlite),
    previous=snap(accounts),
    next=snap(accounts),
    now=0,
  )
  assert_eq(plan.changes.length(), 0)
  assert_true(plan.migration is None)
  assert_eq(plan.journal.entries.length(), 0)
}

///|
test "a plan names the migration after its first change" {
  let plan = @kit.plan(
    journal=@kit.Journal::new(Sqlite),
    previous=@ddl.Snapshot::empty(Sqlite),
    next=snap(accounts),
    now=1700000000000,
  )
  guard plan.migration is Some(migration) else { fail("expected a migration") }
  inspect(migration.tag, content="0000_create_table_accounts")
  inspect(
    migration.sql,
    content=(
      #|CREATE TABLE "accounts" (
      #|  "id" INTEGER PRIMARY KEY NOT NULL
      #|);
      #|
    ),
  )
  debug_inspect(
    plan.journal.entries,
    content=(
      #|[
      #|  {
      #|    idx: 0,
      #|    tag: "0000_create_table_accounts",
      #|    when_: 1700000000000,
      #|    breakpoints: true,
      #|  },
      #|]
    ),
  )
}

///|
test "an explicit name wins over the generated one" {
  let plan = @kit.plan(
    journal=@kit.Journal::new(Sqlite),
    previous=@ddl.Snapshot::empty(Sqlite),
    next=snap(accounts),
    now=0,
    name="initial",
  )
  guard plan.migration is Some(migration) else { fail("expected a migration") }
  inspect(migration.tag, content="0000_initial")
}

///|
test "the second migration follows the first" {
  let first = @kit.plan(
    journal=@kit.Journal::new(Sqlite),
    previous=@ddl.Snapshot::empty(Sqlite),
    next=snap(accounts),
    now=0,
  )
  let second = @kit.plan(
    journal=first.journal,
    previous=snap(accounts),
    next=snap(accounts_with_note),
    now=0,
  )
  guard second.migration is Some(migration) else {
    fail("expected a migration")
  }
  inspect(migration.tag, content="0001_add_column_accounts_note")
  assert_eq(second.journal.entries.length(), 2)
  inspect(@kit.describe(second.changes), content="  add column accounts.note")
}

///|
test "the snapshot a plan carries is the one the next plan diffs against" {
  let plan = @kit.plan(
    journal=@kit.Journal::new(Sqlite),
    previous=@ddl.Snapshot::empty(Sqlite),
    next=snap(accounts),
    now=0,
  )
  guard plan.migration is Some(migration) else { fail("expected a migration") }
  assert_eq(@ddl.Snapshot::from_json_string(migration.snapshot), snap(accounts))
}

///|
test "migration indexes are fixed width until they need not be" {
  inspect(@kit.pad_index(0), content="0000")
  inspect(@kit.pad_index(42), content="0042")
  inspect(@kit.pad_index(12345), content="12345")
}

///|
test "the layout of a migrations directory" {
  let config = @kit.Config::{ dialect: Sqlite, schema: ["src"], out: "db" }
  inspect(config.journal_path(), content="db/meta/_journal.json")
  inspect(config.snapshot_path(3), content="db/meta/0003_snapshot.json")
  inspect(config.migration_path("0003_x"), content="db/0003_x.sql")
}
