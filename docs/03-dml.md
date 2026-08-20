# 3. DML — writing

[← Query](02-query.md) · [JOIN →](04-join.md)

Three statement types, built the same way a `Query` is: as a value, from a
`Table`, running nothing until `run` is called.

## The types

```moonbit
pub struct Insert {
  table_name : String
  columns    : Array[String]
  rows       : Array[Array[SqlValue]]
}

pub struct Update[Cols] {
  table_name : String
  tbl        : String
  cols       : Cols
  sets       : Array[(String, RawExpr)]
  wheres     : Array[RawExpr]
}

pub struct Delete[Cols] {
  table_name : String
  tbl        : String
  cols       : Cols
  wheres     : Array[RawExpr]
}
```

`Insert` carries no `Cols`: by the time a row has been encoded through the
table's `Binding`, there is nothing left to write a typed expression against.
`Update` and `Delete` keep theirs, because their predicates and assignments are
written against the same handles the query builder uses.

## Constructors

```moonbit
pub fn[C, R] insert(Table[C, R], R) -> Insert
pub fn[C, R] insert_many(Table[C, R], Array[R]) -> Insert
pub fn[C, R] insert_except(Table[C, R], R, omit~ : Array[String]) -> Insert

pub fn[C, R] update(Table[C, R], (C) -> Expr[Bool]) -> Update[C]
pub fn[C, R] update_all(Table[C, R]) -> Update[C]

pub fn[C, R] delete(Table[C, R], (C) -> Expr[Bool]) -> Delete[C]
pub fn[C, R] delete_all(Table[C, R]) -> Delete[C]
```

**`update` and `delete` take the predicate as a required argument.** As a step
in a chain it could be forgotten, and forgetting it rewrites the whole table.
To target every row you call `update_all` or `delete_all` and say so by name.

```moonbit
@sql.insert(User::table(), user)
@sql.insert_except(User::table(), user, omit=["id"])  // let the database assign the key
@sql.insert_many(User::table(), [a, b, c])            // one statement, not three

@sql.update(User::table(), u => u.id.eq(7))
|> @sql.Update::set(u => u.name, "bob")

@sql.delete(User::table(), u => u.age.lt(18))
```

```sql
INSERT INTO "users" ("id", "name", "age", "deleted_at")
 VALUES (?, ?, ?, ?)

UPDATE "users" AS u
    SET "name" = ?
  WHERE u."id" = ?

DELETE FROM "users" AS u
  WHERE u."age" < ?
```

### What the writes do

Starting from:

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | bob | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |

`update(users(), u => u.id.eq(2)) |> set(u => u.name, "robert")` —
parameters `["robert", 2]`, and `run` returns `1`:

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | **robert** | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |

`delete(users(), u => u.age.lt(18))` — parameters `[18]`, and `run`
returns `1`:

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 3 | carol | 42 | *NULL* |

Note the parameter order in the UPDATE: `"robert"` comes before `2` even though
the predicate was supplied first, because SET precedes WHERE in the text and
the parameter list always follows the text.

`insert_many` emits one statement rather than N, which keeps the parameters in
a single ordered list — what a driver needs to bind them.

`insert_except` drops named columns from the table's binding while keeping
declaration order. The usual reason is an auto-increment primary key: the
entity carries an `id` field, but the INSERT must let the database assign it.

## Refining

```moonbit
pub fn[C, T : SqlEncode] Update::set(Update[C], (C) -> Column[T], T) -> Update[C]
pub fn[C] Update::filter(Update[C], (C) -> Expr[Bool]) -> Update[C]
pub fn[C] Delete::filter(Delete[C], (C) -> Expr[Bool]) -> Delete[C]
```

`set` selects the column from the table's handles, so the value's type has to
match the column's. Extra `filter`s are ANDed onto whatever the constructor
already put there.

## Building the statement

```moonbit
pub fn Insert::to_sql(Insert, dialect? : Dialect) -> (String, Array[SqlValue]) raise StatementError
pub fn[C] Update::to_sql(Update[C], dialect? : Dialect) -> (String, Array[SqlValue]) raise StatementError
pub fn[C] Delete::to_sql(Delete[C], dialect? : Dialect) -> (String, Array[SqlValue])
```

`Delete::to_sql` does not raise: a delete with no predicate is `delete_all`,
which is a legal statement, so there is nothing left for it to reject.

In `Update`, SET comes before WHERE in the text, so its parameters are emitted
first — keeping the list in textual order.

## What is rejected

| Situation | Error |
|---|---|
| INSERT built with no rows | `EmptyInsert(table~)` |
| a row supplying a different number of values than the binding has columns | `ArityMismatch(table~, expected~, got~)` |
| UPDATE built without any assignment | `EmptyUpdate(table~)` |
| two tables in one query claiming the same alias | `DuplicateAlias(tbl~)` |

All four are `StatementError`: the statement is malformed, independently of
anything the database might say. Failures that come *from* the database are
`DbError` — see [chapter 6](06-execution.md).

## Over a domain-typed table

`insert` takes the table's `R`, so a table built with `table_of` accepts domain
values directly and flattens them through `Binding::contramap` on the way out.

```moonbit
@sql.insert(orders(), Submitted(id=2, items=1, submitted_at="2026-08-01"))
```

```sql
INSERT INTO "orders" ("id", "items", "status", "submitted_at", "tracking")
 VALUES (?, ?, ?, ?, ?)
```

The nulls the row needs are supplied by `Order::to_row`, in one place, rather
than being scattered across call sites.

---

[← Query](02-query.md) · [JOIN →](04-join.md)
