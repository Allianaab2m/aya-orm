///|
/// The entity source most tests in this file start from.
let sample : String =
  #|#aya.table(name="accounts", alias="a")
  #|#aya.index(name="idx_accounts_email", columns="email", unique="true")
  #|pub struct Account {
  #|  #aya.id
  #|  #aya.column(sql_type="INTEGER", autoincrement="true")
  #|  id : AccountId
  #|  email : String
  #|  #aya.column(name="plan_code", sql_type="TEXT", default="'free'")
  #|  plan : Plan
  #|  note : String?
  #|}
  #|

///|
fn snap(
  src : String,
  dialect? : @aya.Dialect = Sqlite,
) -> @ddl.Snapshot raise Error {
  @ddl.snapshot_of(@gen.entities_of(src, name="test.mbt"), dialect~)
}

///|
/// The SQL that takes an empty database to `src`.
fn create(src : String) -> String raise Error {
  @ddl.migration_sql(@ddl.statements(@ddl.Snapshot::empty(Sqlite), snap(src)))
}

///|
/// The SQL that takes `before` to `after`.
fn change(before : String, after : String) -> String raise Error {
  @ddl.migration_sql(@ddl.statements(snap(before), snap(after)))
}

///|
test "built-in types are inferred and explicit ones win" {
  let s = snap(sample)
  debug_inspect(
    s.tables[0].columns.map(c => (c.name, c.ty, c.not_null, c.default_sql)),
    content=(
      #|[
      #|  ("id", "INTEGER", true, None),
      #|  ("email", "TEXT", true, None),
      #|  ("plan_code", "TEXT", true, Some("'free'")),
      #|  ("note", "TEXT", false, None),
      #|]
    ),
  )
}

///|
test "the same entity maps to different types per dialect" {
  let src =
    #|#aya.table(name="events", alias="e")
    #|pub struct Event {
    #|  #aya.id
    #|  id : Int64
    #|  ok : Bool
    #|  weight : Double
    #|  blob : Bytes
    #|}
    #|
  debug_inspect(
    snap(src, dialect=Sqlite).tables[0].columns.map(c => (c.name, c.ty)),
    content=(
      #|[
      #|  ("id", "INTEGER"),
      #|  ("ok", "INTEGER"),
      #|  ("weight", "REAL"),
      #|  ("blob", "BLOB"),
      #|]
    ),
  )
  debug_inspect(
    snap(src, dialect=Postgres).tables[0].columns.map(c => (c.name, c.ty)),
    content=(
      #|[
      #|  ("id", "BIGINT"),
      #|  ("ok", "BOOLEAN"),
      #|  ("weight", "DOUBLE PRECISION"),
      #|  ("blob", "BYTEA"),
      #|]
    ),
  )
}

///|
test "a wrapper type must say what it stores" {
  let src =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : AccountId
    #|}
    #|
  try {
    let _ = snap(src)
    fail("expected UnknownColumnType")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|UnknownColumnType(table="accounts", column="id", ty="AccountId")
        ),
      )
  }
}

///|
test "creating a table writes its columns and indexes" {
  inspect(
    create(sample),
    content=(
      #|CREATE TABLE "accounts" (
      #|  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      #|  "email" TEXT NOT NULL,
      #|  "plan_code" TEXT NOT NULL DEFAULT 'free',
      #|  "note" TEXT
      #|);
      #|--> statement-breakpoint
      #|CREATE UNIQUE INDEX "idx_accounts_email" ON "accounts" ("email");
      #|
    ),
  )
}

///|
test "a foreign key is written on the column that declares it" {
  let src =
    #|#aya.table(name="orders", alias="o")
    #|pub struct Order {
    #|  #aya.id
    #|  id : Int
    #|  #aya.column(references="accounts.id", on_delete="cascade")
    #|  account_id : Int
    #|}
    #|
  inspect(
    create(src),
    content=(
      #|CREATE TABLE "orders" (
      #|  "id" INTEGER PRIMARY KEY NOT NULL,
      #|  "account_id" INTEGER NOT NULL REFERENCES "accounts"("id") ON DELETE CASCADE
      #|);
      #|
    ),
  )
}

///|
test "an added nullable column is a plain ALTER" {
  let before =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|}
    #|
  let after =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  note : String?
    #|}
    #|
  inspect(
    change(before, after),
    content=(
      #|ALTER TABLE "accounts" ADD "note" TEXT;
      #|
    ),
  )
}

///|
test "a new NOT NULL column with no default is refused" {
  let before =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|}
    #|
  let after =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  email : String
    #|}
    #|
  try {
    let _ = change(before, after)
    fail("expected UnsafeChange")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|UnsafeChange(
          #|  table="accounts",
          #|  reason="column `email` is NOT NULL with no default, so existing rows have no value to take; add `#aya.column(default=\"...\")` or make the field optional",
          #|)
        ),
      )
  }
}

///|
test "retyping a column rebuilds the table" {
  let before =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  email : String
    #|}
    #|
  let after =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  email : String?
    #|}
    #|
  inspect(
    change(before, after),
    content=(
      #|PRAGMA foreign_keys=OFF;
      #|--> statement-breakpoint
      #|CREATE TABLE "__new_accounts" (
      #|  "id" INTEGER PRIMARY KEY NOT NULL,
      #|  "email" TEXT
      #|);
      #|--> statement-breakpoint
      #|INSERT INTO "__new_accounts" ("id", "email")
      #|SELECT "id", "email" FROM "accounts";
      #|--> statement-breakpoint
      #|DROP TABLE "accounts";
      #|--> statement-breakpoint
      #|ALTER TABLE "__new_accounts" RENAME TO "accounts";
      #|--> statement-breakpoint
      #|PRAGMA foreign_keys=ON;
      #|
    ),
  )
}

///|
test "dropping an indexed column rebuilds and restores the surviving indexes" {
  let before =
    #|#aya.table(name="accounts", alias="a")
    #|#aya.index(name="idx_accounts_email", columns="email")
    #|#aya.index(name="idx_accounts_id", columns="id")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  email : String
    #|}
    #|
  let after =
    #|#aya.table(name="accounts", alias="a")
    #|#aya.index(name="idx_accounts_id", columns="id")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|}
    #|
  inspect(
    change(before, after),
    content=(
      #|PRAGMA foreign_keys=OFF;
      #|--> statement-breakpoint
      #|CREATE TABLE "__new_accounts" (
      #|  "id" INTEGER PRIMARY KEY NOT NULL
      #|);
      #|--> statement-breakpoint
      #|INSERT INTO "__new_accounts" ("id")
      #|SELECT "id" FROM "accounts";
      #|--> statement-breakpoint
      #|DROP TABLE "accounts";
      #|--> statement-breakpoint
      #|ALTER TABLE "__new_accounts" RENAME TO "accounts";
      #|--> statement-breakpoint
      #|PRAGMA foreign_keys=ON;
      #|--> statement-breakpoint
      #|CREATE INDEX "idx_accounts_id" ON "accounts" ("id");
      #|
    ),
  )
}

///|
test "an unchanged schema produces nothing" {
  assert_eq(@ddl.diff(snap(sample), snap(sample)).length(), 0)
}

///|
test "reordering entity files is not a change" {
  let one =
    #|#aya.table(name="a", alias="a")
    #|pub struct A {
    #|  #aya.id
    #|  id : Int
    #|}
    #|#aya.table(name="b", alias="b")
    #|pub struct B {
    #|  #aya.id
    #|  id : Int
    #|}
    #|
  let other =
    #|#aya.table(name="b", alias="b")
    #|pub struct B {
    #|  #aya.id
    #|  id : Int
    #|}
    #|#aya.table(name="a", alias="a")
    #|pub struct A {
    #|  #aya.id
    #|  id : Int
    #|}
    #|
  assert_eq(@ddl.diff(snap(one), snap(other)).length(), 0)
}

///|
test "a snapshot survives a round trip through its file format" {
  let s = snap(sample)
  let text = s.to_json_string()
  inspect(
    text,
    content=(
      #|{
      #|  "version": "1",
      #|  "dialect": "sqlite",
      #|  "tables": [
      #|    {
      #|      "name": "accounts",
      #|      "columns": [
      #|        {
      #|          "name": "id",
      #|          "type": "INTEGER",
      #|          "not_null": true,
      #|          "primary_key": true,
      #|          "autoincrement": true,
      #|          "unique": false,
      #|          "default": null,
      #|          "references": null
      #|        },
      #|        {
      #|          "name": "email",
      #|          "type": "TEXT",
      #|          "not_null": true,
      #|          "primary_key": false,
      #|          "autoincrement": false,
      #|          "unique": false,
      #|          "default": null,
      #|          "references": null
      #|        },
      #|        {
      #|          "name": "plan_code",
      #|          "type": "TEXT",
      #|          "not_null": true,
      #|          "primary_key": false,
      #|          "autoincrement": false,
      #|          "unique": false,
      #|          "default": "'free'",
      #|          "references": null
      #|        },
      #|        {
      #|          "name": "note",
      #|          "type": "TEXT",
      #|          "not_null": false,
      #|          "primary_key": false,
      #|          "autoincrement": false,
      #|          "unique": false,
      #|          "default": null,
      #|          "references": null
      #|        }
      #|      ],
      #|      "indexes": [
      #|        {
      #|          "name": "idx_accounts_email",
      #|          "columns": [
      #|            "email"
      #|          ],
      #|          "unique": true
      #|        }
      #|      ]
      #|    }
      #|  ]
      #|}
      #|
    ),
  )
  assert_eq(@ddl.Snapshot::from_json_string(text), s)
}

///|
test "a migration file splits back into its statements" {
  let text = create(sample)
  assert_eq(@ddl.split_migration(text).length(), 2)
}

///|
test "migrations are named after what they do" {
  let before =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|}
    #|
  let after =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  note : String?
    #|}
    #|
  inspect(
    @ddl.auto_name(@ddl.diff(snap(before), snap(after))),
    content="add_column_accounts_note",
  )
  inspect(
    @ddl.auto_name(@ddl.diff(@ddl.Snapshot::empty(Sqlite), snap(sample))),
    content="create_table_accounts",
  )
  inspect(@ddl.auto_name([]), content="migration")
}

///|
test "postgres has a type table but no emitter yet" {
  try {
    let _ = @ddl.statements(
      @ddl.Snapshot::empty(Postgres),
      snap(sample, dialect=Postgres),
    )
    fail("expected UnsupportedDialect")
  } catch {
    e =>
      debug_inspect(
        e,
        content=(
          #|UnsupportedDialect(
          #|  dialect="postgres",
          #|  reason="the type mapping is in place but the DDL emitter is not written yet",
          #|)
        ),
      )
  }
}

///|
test "a column that becomes NOT NULL takes its default on the way across" {
  let before =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  plan : String?
    #|}
    #|
  let after =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  #aya.column(default="'free'")
    #|  plan : String
    #|}
    #|
  inspect(
    change(before, after),
    content=(
      #|PRAGMA foreign_keys=OFF;
      #|--> statement-breakpoint
      #|CREATE TABLE "__new_accounts" (
      #|  "id" INTEGER PRIMARY KEY NOT NULL,
      #|  "plan" TEXT NOT NULL DEFAULT 'free'
      #|);
      #|--> statement-breakpoint
      #|INSERT INTO "__new_accounts" ("id", "plan")
      #|SELECT "id", coalesce("plan", 'free') FROM "accounts";
      #|--> statement-breakpoint
      #|DROP TABLE "accounts";
      #|--> statement-breakpoint
      #|ALTER TABLE "__new_accounts" RENAME TO "accounts";
      #|--> statement-breakpoint
      #|PRAGMA foreign_keys=ON;
      #|
    ),
  )
}

///|
test "a column that becomes NOT NULL with no default is refused" {
  let before =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  plan : String?
    #|}
    #|
  let after =
    #|#aya.table(name="accounts", alias="a")
    #|pub struct Account {
    #|  #aya.id
    #|  id : Int
    #|  plan : String
    #|}
    #|
  try {
    let _ = change(before, after)
    fail("expected UnsafeChange")
  } catch {
    e =>
      inspect(
        e,
        content="table `accounts`: column `plan` is NOT NULL with no default, so existing rows have no value to take; add `#aya.column(default=\"...\")` or make the field optional",
      )
  }
}
