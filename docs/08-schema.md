# 8. Schema and migrations

[← Repository](07-repository.md) · [Design notes →](09-design.md)

The same annotations that produce column handles also produce the database
schema. The row type is the single definition; the DDL is derived from it, and
`cairn-kit` works out what changed since last time.

## Configuration

```json
// cairn.json
{
  "dialect": "sqlite",
  "schema": ["src/example"],
  "out": "migrations"
}
```

Every key is optional. `--schema`, `--out` and `--dialect` override the file for
one run, and `cairn-kit init` writes a starting config.

## Commands

```bash
cairn-kit status      show the diff against the last snapshot, writing nothing
cairn-kit generate    write the next migration from that diff
cairn-kit ddl         print CREATE statements for the whole schema
cairn-kit codegen     regenerate the .g.mbt companions
cairn-kit init        write cairn.json and migrations/
```

Inside this repository they run as `moon run src/kit/cmd -- <subcommand>`.

## What it writes

```
migrations/
  0000_initial.sql
  0001_add_column_users_nickname.sql
  meta/
    _journal.json          what has been generated, and for which dialect
    0000_snapshot.json     the schema as of that migration
    0001_snapshot.json
```

The diff is **against the previous snapshot, not against a database**. Nothing
needs a connection to generate a migration, and CI gets the same answer you do.
Snapshots are written with a fixed key order, so their diffs are reviewable.

File names come from the change itself, so the directory reads as a schema
changelog. `--name` overrides them.

```
$ moon run src/kit/cmd -- status
  add column users.nickname
run `cairn-kit generate` to write the migration

$ moon run src/kit/cmd -- generate
  add column users.nickname
cairn-kit: wrote migrations/0001_add_column_users_nickname.sql
```

```sql
ALTER TABLE "users" ADD "nickname" TEXT;
```

## Column types

The inferred types are exactly the ones `SqlValue` can hold.

| MoonBit | SQLite | PostgreSQL |
|---|---|---|
| `Int` | `INTEGER` | `INTEGER` |
| `Int64` | `INTEGER` | `BIGINT` |
| `Bool` | `INTEGER` | `BOOLEAN` |
| `Double` | `REAL` | `DOUBLE PRECISION` |
| `String` | `TEXT` | `TEXT` |
| `Bytes` | `BLOB` | `BYTEA` |
| `T?` | the type of `T`, without `NOT NULL` | same |

A wrapper type has to say what it stores. Guessing is how a new type around an
`Int` quietly ends up in a `TEXT` column.

```moonbit
#cairn.table(name="accounts", alias="a")
#cairn.index(name="idx_accounts_email", columns="email", unique="true")
pub(all) struct Account {
  #cairn.id
  #cairn.column(sql_type="INTEGER")
  id : AccountId
  email : String
  #cairn.column(sql_type="TEXT", default="'free'")
  plan : Plan
} derive(Debug, Eq)
```

```sql
CREATE TABLE "accounts" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "email" TEXT NOT NULL,
  "plan" TEXT NOT NULL DEFAULT 'free'
);
--> statement-breakpoint
CREATE UNIQUE INDEX "idx_accounts_email" ON "accounts" ("email");
```

## Attributes

These extend the table in [chapter 1](01-table.md); nothing here changes what
the generated MoonBit looks like.

| Attribute | On | Argument | Effect |
|---|---|---|---|
| `#cairn.index` | struct | `name=` | index name, defaulting to `idx_<table>_<columns>` |
| | | `columns=` | the **fields** to index, comma-separated |
| | | `unique=` | `"true"` for a unique index |
| `#cairn.column` | field | `sql_type=` | SQL type; required for a type `SqlValue` does not cover |
| | | `default=` | SQL expression, emitted verbatim after `DEFAULT` |
| | | `unique=` | `"true"` for a column-level `UNIQUE` |
| | | `autoincrement=` | `"true"`, on an `INTEGER PRIMARY KEY` |
| | | `references=` | a foreign key, written as `"tickets.id"` |
| | | `on_delete=` / `on_update=` | `cascade`, `restrict`, `set null`, `set default`, `no action` |

An index names fields rather than columns, so renaming a column with
`#cairn.column(name=...)` does not silently break its index.

It is `sql_type=` rather than `type=` because `moon fmt` rewrites
`#cairn.column(type="...")` into `##cairn.column(...)`, which then fails to lex.
Writing `type=` is rejected with that explanation rather than accepted and
broken by the next person who formats the file.

Nullability comes from **the type**, not from an attribute: `String?` is
nullable, `String` is `NOT NULL`. An attribute that could override it would let
the schema disagree with what the decoder already believes.

## Living with SQLite

SQLite's `ALTER TABLE` can add and drop plain columns and nothing else. A type
change, a new constraint, or dropping an indexed column leaves no option but to
rebuild the table, so that is what comes out:

```sql
PRAGMA foreign_keys=OFF;
--> statement-breakpoint
CREATE TABLE "__new_accounts" (
  "id" INTEGER PRIMARY KEY NOT NULL,
  "email" TEXT
);
--> statement-breakpoint
INSERT INTO "__new_accounts" ("id", "email")
SELECT "id", "email" FROM "accounts";
--> statement-breakpoint
DROP TABLE "accounts";
--> statement-breakpoint
ALTER TABLE "__new_accounts" RENAME TO "accounts";
--> statement-breakpoint
PRAGMA foreign_keys=ON;
```

Statements are separated by `--> statement-breakpoint` rather than by `;`,
because a `DEFAULT` expression or a trigger body contains semicolons of its own.

`CREATE TABLE` statements are ordered so a table follows everything it
references. SQLite would not mind — it resolves foreign keys lazily — but the
file is also something a person reads.

## Where it errs on the safe side

| Situation | Behaviour |
|---|---|
| a column vanishing and another appearing | a drop and an add; renames are not guessed |
| a new `NOT NULL` column with no default | refused, naming the column |
| a column becoming `NOT NULL` | copied through `coalesce("col", <default>)` |
| a wrapper type with no `sql_type=` | refused, naming the MoonBit type |
| `type=` instead of `sql_type=` | refused, because `moon fmt` would break the file |
| two entities claiming one table name | refused |
| the journal and the config disagreeing on dialect | refused |

**Renames are not detected.** Nothing in the source says whether a vanished
column and a new one are the same column, and guessing wrong silently deletes
data. A drop and an add is at least visible in the generated SQL before it runs.

**Adding a `NOT NULL` column with no default is refused.** Neither `ALTER TABLE`
nor a rebuild has a value to put in the existing rows. Give it a `default=`, or
make the field `T?`. A column that *becomes* `NOT NULL` is copied through
`coalesce`, because its default says nothing about the NULLs already stored.

Dropping a column without a rebuild uses `ALTER TABLE ... DROP COLUMN`, which
needs SQLite 3.35 (2021) or newer.

## Not built yet

PostgreSQL has its type table but no DDL emitter; `generate` targets SQLite.
There is no `migrate` subcommand that runs the `.sql` files through an
`Executor`. `#cairn.id` marks a single column, so composite primary keys and
multi-column unique constraints have no spelling.

---

[← Repository](07-repository.md) · [Design notes →](09-design.md)
