# 5. Aggregation

[← JOIN](04-join.md) · [Execution →](06-execution.md)

## The type

```moonbit
type Reducer[Out]   // abstract
```

Structurally a `Reducer` is a `Selection`: the same expressions-plus-positional-
reader pair. The type is deliberately **separate and opaque**, and that is the
whole design.

A `Reducer` may only hold aggregate expressions, and no constructor exists that
could put anything else in one. So projecting a bare, ungrouped column next to
an aggregate — which SQL rejects — **cannot be written in the first place**.
`Query::reduce` and `Query::group_by` ask for a `Reducer` rather than a
`Selection` for exactly that reason.

## The aggregates

```moonbit
pub fn count() -> Reducer[Int]
pub fn[T] count_of(Column[T]) -> Reducer[Int]
pub fn[T : SqlDecode + SqlOrd] min(Column[T]) -> Reducer[T?]
pub fn[T : SqlDecode + SqlOrd] max(Column[T]) -> Reducer[T?]
pub fn[T : SqlDecode + SqlNum] sum(Column[T]) -> Reducer[T?]
pub fn[T : SqlNum]             avg(Column[T]) -> Reducer[Double?]
```

| | SQL | Over no rows |
|---|---|---|
| `count()` | `COUNT(*)` | `0` |
| `count_of(c)` | `COUNT(c)` — NULLs not counted | `0` |
| `min(c)` / `max(c)` | `MIN(c)` / `MAX(c)` | `None` |
| `sum(c)` | `SUM(c)` | `None` |
| `avg(c)` | `AVG(c)` | `None` |

**`count` reads as `Int` while the rest read as `T?`**, matching SQL: `COUNT(*)`
over no rows is zero, whereas `MIN` is NULL.

`avg` returns `Double?` whatever the column's type, because an average of
integers is not generally an integer.

`sum` and `avg` require `SqlNum`; `min` and `max` require `SqlOrd`. Both are
marker traits with no methods, there only to keep a `Column[String]` from being
summed.

## Composing

```moonbit
pub fn[A, B] Reducer::zip(Reducer[A], Reducer[B]) -> Reducer[(A, B)]
pub fn[A, B] Reducer::map(Reducer[A], (A) -> B raise DecodeError) -> Reducer[B]
```

Acadia offers `map2` through `map9` here; `zip` plus `map` covers the same
ground without an arity ladder.

## Reducing the whole result

```moonbit
pub fn[C, A, S] Query::reduce(Query[C, A], (C) -> Reducer[S]) -> Query[C, S]
```

The projection becomes the aggregates and nothing else, so the result is one
row. Note `A` becomes `S` while `C` is untouched: the column handles are still
in scope, but what a row decodes to is now the summary.

**`users`**

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | bob | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |
| 4 | dave | 25 | 2026-01-09 |

```moonbit
@sql.from(users())
|> @sql.Query::filter(u => u.deleted_at.is_none())
|> @sql.Query::reduce(u => @sql.count().zip(@sql.min(u.age)).zip(@sql.max(u.age)))
```

```sql
SELECT COUNT(*), MIN(u."age"), MAX(u."age")
  FROM "users" AS u
 WHERE u."deleted_at" IS NULL
```

**Result** — one row, `((Int, Int?), Int?)`

| COUNT(*) | MIN(age) | MAX(age) |
|---------:|---------:|---------:|
| 3 | 17 | 42 |

which decodes to `((3, Some(17)), Some(42))` — the nesting comes from chaining
`zip`, and `map` is how you flatten it into something of your own. `dave` is
excluded by the filter, so the count is 3 rather than 4.

Run it with `one`: there is always exactly one row.

## Grouping

```moonbit
pub fn[C, A, K : SqlDecode, S] Query::group_by(
  Query[C, A],
  (C) -> Column[K],      // the key
  (C) -> Reducer[S],     // the summary
) -> Query[C, (K, S)]
```

The grouping key is the only non-aggregate the projection can contain, and it
is exactly the column being grouped by, so **the result is always a legal
aggregate query**. Rows come back as `(K, S)` pairs.

```moonbit
@sql.from(users())
|> @sql.Query::group_by(u => u.name, u => @sql.count().zip(@sql.avg(u.age)))
```

```sql
SELECT u."name", COUNT(*), AVG(u."age")
  FROM "users" AS u
 GROUP BY u."name"
```

Run it with `run`: one row per distinct key.

Grouping is more interesting across a join, where the key genuinely repeats.
Counting each author's posts over the two tables from
[chapter 4](04-join.md):

```moonbit
@sql.from(users())
|> @sql.Query::join(posts(), (u, p) => u.id.eq_col(p.author_id))
|> @sql.Query::group_by(
  @sql.split2((u, _p) => u.name),
  @sql.split2((_u, p) => @sql.count_of(p.id)),
)
```

```sql
SELECT u."name", COUNT(p."id")
  FROM "users" AS u
  JOIN "posts" AS p ON u."id" = p."author_id"
 GROUP BY u."name"
```

**Result** — `Array[(String, Int)]`

| name | COUNT(p."id") |
|------|--------------:|
| alice | 2 |
| carol | 1 |

`bob` is absent, not zero: an inner join never produced a row for him, so there
is no group to count. To get him back with a `0`, outer-join instead and count a
column reached through the wrapper — `count_of` skips NULLs, and the padded row
is all NULL:

```moonbit
|> @sql.Query::left_join(posts(), (u, p) => u.id.eq_col(p.author_id))
|> @sql.Query::group_by(
  @sql.split2((u, _p) => u.name),
  @sql.split2((_u, p) => @sql.count_of(p.col(x => x.id))),
)
```

| name | COUNT(p."id") |
|------|--------------:|
| alice | 2 |
| bob | 0 |
| carol | 1 |

Filters, limits and joins compose with grouping in the usual way — `filter`
lands in WHERE, before the grouping, and `limit` caps how many groups come
back.

---

[← JOIN](04-join.md) · [Execution →](06-execution.md)
