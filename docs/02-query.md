# 2. Query — reading

[← Table](01-table.md) · [DML →](03-dml.md)

A `Query` is a value. Building one runs nothing; `to_sql` turns it into text
and parameters, and `run` / `one` / `first` ([chapter 6](06-execution.md)) send
it to a database.

## The type

```moonbit
pub struct Query[Cols, A] {
  source      : String
  source_tbl  : String
  joins       : Array[Join]
  cols        : Cols
  projection  : Array[RawExpr]
  wheres      : Array[RawExpr]
  group       : Array[RawExpr]
  order       : Array[OrderKey]
  limit_n     : Int?
  decode      : (Row) -> A raise DecodeError
}
```

Two parameters, two jobs:

- **`Cols`** is what the combinators are written *against* — the column handles
  in scope. It starts as one table's `Cols` struct and becomes a tuple once
  joins are added.
- **`A`** is what a row *becomes*. It starts as the table's entity and changes
  only when `map`, `reduce` or `group_by` says so.

Every combinator returns a new `Query`; nothing is mutated in place.

## The combinators

```moonbit
pub fn[C, R] from(Table[C, R]) -> Query[C, R]

pub fn[C, A]       Query::filter(Query[C, A], (C) -> Expr[Bool])      -> Query[C, A]
pub fn[C, A]       Query::order_by(Query[C, A], (C) -> Array[OrderKey]) -> Query[C, A]
pub fn[C, A]       Query::limit(Query[C, A], Int)                     -> Query[C, A]
pub fn[C, R, O]    Query::map(Query[C, R], (C) -> Selection[O])       -> Query[C, O]
pub fn[C, D, A]    Query::map_cols(Query[C, A], (C) -> D)             -> Query[D, A]
```

Each takes a **function of the column handles** rather than the handles
themselves, so a predicate can only mention columns the query actually has in
scope. Adding a table with `join` widens `C`, and only then can the new table's
columns be named.

| Combinator | Changes | Leaves alone |
|---|---|---|
| `filter` | `wheres` (accumulates, ANDed) | everything else |
| `order_by` | `order` (replaces; the last call wins) | everything else |
| `limit` | `limit_n` | everything else |
| `map` | `projection`, `decode`, and so `A` | `cols`, and so `C` |
| `map_cols` | `cols`, and so `C` | the SQL built so far |
| `join` / `left_join` | `joins`, `cols` | `projection`, `decode` |
| `reduce` / `group_by` | `projection`, `group`, `decode` | `cols` |

`map` and `map_cols` are the pair worth keeping straight: `map` changes **what
comes back**, `map_cols` changes **how you refer to the columns**. `map_cols`
touches no SQL at all — see [chapter 4](04-join.md), where it earns its keep.

### A worked example

Everything below reads against this table.

**`users`**

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | bob | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |
| 4 | dave | 25 | 2026-01-09 |

```moonbit
@aya.from(User::table())
|> @aya.Query::filter(u => u.age.gte(18) & u.deleted_at.is_none())
|> @aya.Query::map(u => @aya.sel(u.name))
|> @aya.Query::order_by(u => [u.name.asc()])
|> @aya.Query::limit(20)
```

```sql
SELECT u."name"
  FROM "users" AS u
 WHERE u."age" >= ? AND u."deleted_at" IS NULL
 ORDER BY u."name" ASC
 LIMIT ?
-- parameters: [18, 20]
```

**Result** — `Array[String]`

| name |
|------|
| alice |
| carol |

`bob` is dropped by `age >= 18`, `dave` by `deleted_at IS NULL`. Note what the
`map` did to the *type*: the projection is now one column, so `A` is `String`
and no longer the `User` the table started with. Drop the `map` and the same
filter yields `Array[User]` with every column.

## The expression language

```moonbit
pub struct Column[T] { tbl : String; name : String }
pub struct Expr[T](RawExpr)
```

Both carry a **phantom `T`**. It never reaches the SQL; it exists so that
`u.age.eq("eighteen")` does not compile.

The comparison operators live directly on `Column[T]`, because a column is the
overwhelmingly common left-hand side. `Column::expr()` lifts to `Expr[T]` when
you are assembling something the column shorthand does not cover.

| On `Column[T]` and `Expr[T]` | SQL | Requires |
|---|---|---|
| `eq(v)` / `ne(v)` | `= ?` / `<> ?` | `T : SqlEncode` |
| `gt(v)` / `gte(v)` / `lt(v)` / `lte(v)` | `> ?` etc. | `T : SqlEncode + SqlOrd` |
| `eq_col(other)` | `a."x" = b."y"` | — |
| `in_([v, ..])` | `IN (?, ?)` | `T : SqlEncode` |
| `is_none()` / `is_some()` | `IS NULL` / `IS NOT NULL` | receiver is `T?` |
| `asc()` / `desc()` | `ORDER BY … ASC` | `T : SqlOrd` |
| `a & b` / `a \| b` | `AND` / `OR` | both `Expr[Bool]` |

`&` and `\|` are `BitAnd` / `BitOr` on `Expr[Bool]`, so precedence is MoonBit's
and the emitter adds brackets where SQL needs them.

```moonbit
|> @aya.Query::filter(u => (u.age.gte(18) | u.name.eq("root")) & u.deleted_at.is_none())
```

```sql
 WHERE (u."age" >= ? OR u."name" = ?) AND u."deleted_at" IS NULL
-- parameters: [18, "root"]
```

Against the table above that keeps alice, bob and carol — `root` matches
nobody, but `OR` widens the age test to let bob through, and `dave` is still
excluded by the soft-delete check.

Nullable columns stay orderable and comparable — SQL happily sorts a column
holding NULLs, and refusing `T?` would reject `ORDER BY submitted_at DESC`.

## Choosing what comes back

```moonbit
pub fn[T : SqlDecode] sel(Column[T]) -> Selection[T]
pub fn[A : SqlDecode, B : SqlDecode] sel2(Column[A], Column[B]) -> Selection[(A, B)]
pub fn[A : SqlDecode, B : SqlDecode, C : SqlDecode] sel3(Column[A], Column[B], Column[C]) -> Selection[(A, B, C)]
```

Beyond three columns, `zip` and `into2` / `into3` compose without an arity
ladder:

```moonbit
|> @aya.Query::map(u => @aya.sel2(u.id, u.name).into2((id, name) => Summary::{ id, name }))
```

Without a `map`, a query projects the table's `all` and decodes to the table's
entity. Over a domain-typed table that means domain values come straight back,
and the row type never appears.

## Building the statement

```moonbit
pub fn[C, A] Query::to_sql(
  Query[C, A],
  dialect? : Dialect,   // Sqlite (default) | Postgres
  shape? : RowShape,    // Plain (default) | Typed
) -> (String, Array[SqlValue]) raise StatementError
```

The parameter list is always in **textual order**, so placeholder *n* in the
text is parameter *n* in the list — which is what makes `$1`-style numbering
and `?`-style positional binding interchangeable.

`run` / `one` / `first` call `to_sql` for you with the dialect and row shape
the executor asked for. Call it directly to log a statement, or to test one
without a database.

Two things can go wrong at this stage, both `StatementError`:

| | |
|---|---|
| `DuplicateAlias(tbl~)` | two tables in one query claim the same alias |
| the rest | see [DML](03-dml.md) |

---

[← Table](01-table.md) · [DML →](03-dml.md)
