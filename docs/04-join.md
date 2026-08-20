# 4. JOIN

[← DML](03-dml.md) · [Aggregation →](05-aggregate.md)

Joining widens the query's `Cols` parameter. Everything downstream — filters,
projections, ordering — then sees both tables' handles, and nothing else.

## The types

```moonbit
pub fn[C1, C2, R2, A] Query::join(
  Query[C1, A], Table[C2, R2], (C1, C2) -> Expr[Bool],
) -> Query[(C1, C2), A]

pub fn[C1, C2, R2, A] Query::left_join(
  Query[C1, A], Table[C2, R2], (C1, C2) -> Expr[Bool],
) -> Query[(C1, Nullable[C2, R2]), A]
```

Note what does **not** change: `A`. A join adds a table to the FROM clause and
nothing more; what a row decodes to is still whatever the projection says.

### A worked example

Both examples in this chapter read against these two tables.

**`users`**

| id | name | age | deleted_at |
|---:|------|----:|------------|
| 1 | alice | 30 | *NULL* |
| 2 | bob | 17 | *NULL* |
| 3 | carol | 42 | *NULL* |

**`posts`**

| id | author_id | title |
|---:|----------:|-------|
| 10 | 1 | hello |
| 11 | 1 | draft |
| 12 | 3 | notes |

`bob` has written nothing. That is the row the two join kinds disagree about.

```moonbit
@sql.from(User::table())
|> @sql.Query::join(Post::table(), (u, p) => u.id.eq_col(p.author_id))
|> @sql.Query::filter(c => c.0.age.gte(18) & c.1.title.ne("draft"))
|> @sql.Query::map(c => @sql.sel2(c.0.name, c.1.title))
|> @sql.Query::order_by(c => [c.1.id.desc()])
```

```sql
SELECT u."name", p."title"
  FROM "users" AS u
  JOIN "posts" AS p ON u."id" = p."author_id"
 WHERE u."age" >= ? AND p."title" <> ?
 ORDER BY p."id" DESC
-- parameters: [18, "draft"]
```

**Result** — `Array[(String, String)]`

| name | title |
|------|-------|
| carol | notes |
| alice | hello |

Three rows come out of the join — alice/hello, alice/draft, carol/notes — and
the filter drops alice/draft. `bob` never appears at all: an inner join has
nothing to pair him with. `ORDER BY p."id" DESC` is why carol precedes alice.

## Taking the tuple apart

Acadia's joins produce tuples too (`intersect : … -> Rows (a, b)`). The
difference is that Elm can destructure them in a lambda parameter,
`\((a, b), c) -> …`, and **MoonBit has no such syntax**. cairn supplies two
tools instead, so `.0.0` lives in the library and not in your code.

### Two tables: `split2`

```moonbit
pub fn[A, B, R] split2((A, B) -> R) -> ((A, B)) -> R
```

It turns a function of two named arguments into the single-argument function
the combinators expect.

```moonbit
|> @sql.Query::filter(@sql.split2((u, p) => u.age.gte(18) & p.title.ne("draft")))
|> @sql.Query::map(@sql.split2((_u, p) => @sql.sel(p.title)))
```

Deliberately stops at two. With three tables the arguments start needing
positional `_` placeholders, at which point naming reads better than
destructuring.

### Three or more: name the shape with `map_cols`

```moonbit
pub fn[C, D, A] Query::map_cols(Query[C, A], (C) -> D) -> Query[D, A]
```

Chained joins nest to the left — `((C1, C2), C3)` — and indexing through that
nesting at every later step reads badly. `map_cols` collapses it once, into a
struct with names or a flat tuple. Only the handles change; the SQL built so
far does not.

```moonbit
pub struct TicketJoin {
  ticket     : TicketCols
  assignment : @sql.Nullable[AssignmentCols, AssignmentRow]
  closure    : @sql.Nullable[ClosureCols, ClosureRow]
}

|> @sql.Query::map_cols(c => { ticket: c.0.0, assignment: c.0.1, closure: c.1 })
|> @sql.Query::filter(j => j.ticket.id.eq(id))
```

The nesting is now confined to one line. Everything after it reads
`j.assignment`, not `c.0.1`.

If a struct feels like too much, a `typealias` at least makes the signature
readable:

```moonbit
pub typealias ((UserCols, PostCols), TagCols) as UserPostTag
```

## LEFT JOIN and `Nullable`

```moonbit
type Nullable[C, R]                                     // abstract: no exposed representation

pub fn[C, R, T] Nullable::col(Nullable[C, R], (C) -> Column[T]) -> Column[T?]
pub fn[C, R]    Nullable::row(Nullable[C, R])                   -> Selection[R?]
```

The right-hand side of an outer join comes back wrapped. **There is no route to
a `Column[T]` inside it** — the wrapper has no exposed representation, so the
nullability an outer join introduces cannot be lost by accident. Exactly two
ways in:

```moonbit
c.1.col(p => p.title)   // Column[String?]   -- when you want one column
c.1.row()               // Selection[Post?]  -- when you want the whole row
```

`row()` is usually closer to what an outer join means. It is not saying that
each column independently might be NULL; it is saying **the row on the right
either exists or does not**, and inside `Some` every field keeps the type the
table declared.

```moonbit
@sql.from(User::table())
|> @sql.Query::left_join(Post::table(), (u, p) => u.id.eq_col(p.author_id))
|> @sql.Query::map(c => @sql.sel(c.0.name).zip(c.1.row()))
```

```sql
SELECT u."name", p."id", p."title"
  FROM "users" AS u
  LEFT JOIN "posts" AS p ON u."id" = p."author_id"
```

`row()` expands to the joined table's whole projection, which is why the SELECT
list has three columns for a two-part result.

**Result** — `Array[(String, Post?)]`

| name | `Post?` |
|------|---------|
| alice | `Some({ id: 10, title: "hello" })` |
| alice | `Some({ id: 11, title: "draft" })` |
| bob | `None` |
| carol | `Some({ id: 12, title: "notes" })` |

`bob` is the whole point. An inner join loses him; the outer join keeps him
with `None` on the right, and the type says so — you cannot reach a `Post`
there without handling the `None`.

The `on` condition sees the joined table's *raw* columns, not the wrapper: a
join condition is evaluated before the outer-join padding, so nullability does
not apply to it. What the query carries afterwards is the wrapper.

### How "no match" is detected

`Selection::optional` reads the projection as absent when **every column on the
right is NULL**. That is always right for a projection containing a column the
database never leaves NULL, and `Table::all` always includes one. For a
hand-built projection of entirely nullable columns, name the deciding column:

```moonbit
pub fn[Out] Selection::optional_on(Selection[Out], key~ : Int) -> Selection[Out?]
```

`key` indexes into that projection's own columns, counting from zero.

### The absence of a row is a query

Reaching a column of an outer-joined table yields `Column[T?]`, which is
exactly what "nothing matched" needs to be tested against:

```moonbit
|> @sql.Query::filter(j => j.assignment.col(a => a.ticket_id).is_none())
// -> WHERE ta."ticket_id" IS NULL
```

## Aliases

Every table in one query needs its own alias, otherwise `u."id"` silently
refers to whichever one the database picks. `Query::to_sql` raises
`DuplicateAlias(tbl~)` rather than emit that.

Aliases are fixed per table (`#cairn.table(alias="u")`), not assigned per
query, which is why **self-joins are not expressible yet** — see
[design notes](08-design.md).

---

[← DML](03-dml.md) · [Aggregation →](05-aggregate.md)
