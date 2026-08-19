# cairn

A thin, type-safe SQL toolkit for MoonBit.

**English** | [日本語](README_ja.md)

Write one row type and you get column handles, a projection, a decoder and an
encoder generated for you, then build typed queries and DML on top. **The row
type and the domain entity are treated as separate things**, and the mapping
between them is yours to write. The query pipeline follows
[Acadia](https://acadia.engineering/).

Execution is delegated to whatever implements the `Driver` trait, so cairn
itself depends on no particular database.

## How the types got here

```mermaid
flowchart LR
    S0["0. name-keyed Row"] --> S1["1. positional"]
    S1 --> S2["2. codegen"]
    S2 --> S3["3. DML"]
    S3 --> S4["4. JOIN"]
    S4 --> S5["5. row vs domain"]
    S5 --> S6["6. outer-join nullability"]
    S6 --> S7["7. execution"]

    S0 -.- D0["Table held a decoder<br/>row.get(name)"]
    S1 -.- D1["Selection introduced<br/>projection + decoder as one"]
    S2 -.- D2["Selection::new exposed<br/>so generated code can build it"]
    S3 -.- D3["Binding introduced<br/>Table gained write"]
    S4 -.- D4["Query gained joins<br/>Cols became a tuple"]
    S5 -.- D5["Binding::contramap<br/>table_of names the seam"]
    S6 -.- D6["abstract Nullable<br/>reachable only via col / row"]
    S7 -.- D7["Driver trait<br/>transaction combinator"]

    classDef note fill:#f6f8fa,stroke:#d0d7de,color:#24292f
    class D0,D1,D2,D3,D4,D5,D6,D7 note
```

What changed in `Table` and `Query` at each step.

| Step | Change | Why |
|---|---|---|
| 0 | `Table { cols, decoder }`, `Row` a map from column name to value | first sketch |
| 1 | `Row = ArrayView[SqlValue]`, `Selection[Out]` carries projection and decoder, `Table { .., all }` | projection order and decode order can no longer disagree |
| 2 | `Selection::new` made public | `Selection` is a `pub struct`, so the package holding generated code could not build one |
| 3 | `Binding[In]` added, `Table { .., write }` | INSERT needs the value-to-row direction |
| 4 | `Query { .., joins }`, `Query::join` makes `Cols` a tuple | more than one table |
| 5 | `Binding::contramap` added, generator emits `table_of`, attribute became `#cairn.table` | the row type and the domain type are different things, and the mapping is written by hand |
| 6 | `left_join` returns the abstract `Nullable[C, R]`, `Selection::optional` added | make outer-join nullability enforced by the type |
| 7 | `Driver` trait and `transaction`, `run` / `one` / `first` on every statement | build the SQL *and* run it |

### 1. Why `Selection`

`Selection[Out]` binds "which columns to read" (`exprs`) and "how to turn a row
into a value" (`read`) into one value. Kept apart, they break the usual way:
a column gets added to the projection and the decoder is not updated.

```mermaid
flowchart LR
    E["entity definition<br/>field order"] --> P["exprs<br/>SELECT column order"]
    E --> R["read<br/>row 0, row 1, ..."]
    P -.->|same order| R
```

`read` reads **by position**. That is fragile by hand, but the generator emits
`exprs` and `read` from one pass over the same field list, so in practice they
cannot drift.

### 3. Reading and writing are mirrors

`Binding[In]` is the reflection of `Selection[Out]`.

```mermaid
flowchart LR
    DB1[("DB")] -->|"ArrayView&lt;SqlValue&gt;"| SEL["Selection&lt;R&gt;<br/>exprs / read"]
    SEL --> R1["R"]
    R2["R"] --> BND["Binding&lt;R&gt;<br/>columns / write"]
    BND -->|"Array&lt;SqlValue&gt;"| DB2[("DB")]
```

Both come from the same field list, so a SELECT and an INSERT cannot disagree
about what each column position means.

## The types today

```mermaid
classDiagram
    class Table~Cols,R~ {
        table_name : String
        tbl : String
        cols : Cols
        all : Selection~R~
        write : Binding~R~
    }
    class Selection~Out~ {
        exprs : Array~RawExpr~
        read : row to Out
    }
    class Binding~In~ {
        columns : Array~String~
        write : In to values
    }
    class Query~Cols,A~ {
        source : String
        source_tbl : String
        joins : Array~Join~
        cols : Cols
        projection : Array~RawExpr~
        wheres : Array~RawExpr~
        order : Array~OrderKey~
        limit_n : Int?
        decode : row to A
    }
    class Column~T~ {
        tbl : String
        name : String
    }
    class Expr~T~ {
        raw : RawExpr
    }
    class RawExpr {
        Col
        Lit
        Bin
        Unary
        InList
        Agg
    }
    class Insert
    class Update~Cols~
    class Delete~Cols~

    Table --> Selection : all
    Table --> Binding : write
    Table --> Query : from
    Table --> Insert : insert
    Table --> Update : update
    Table --> Delete : delete
    Query --> RawExpr : projection / wheres
    Selection --> RawExpr : exprs
    Column --> Expr : expr
    Expr --> RawExpr : raw
```

`Cols` is generated per entity (`UserCols` and friends): a struct of
`Column[T]` fields. The `T` in `Expr[T]` and `Column[T]` is a phantom type that
never reaches the SQL. It exists only to keep comparisons honest — you cannot
hand a string to a `Column[Int]`.

The comparison operators live directly on `Column[T]`, so you write
`u.age.gte(18)`. The two types are not merged because `Column` also carries a
name, which `sel`, `Binding` and `Update::set` need, while a general expression
has no name to give. `Column::expr()` remains as the way out when you are
assembling an expression directly, such as an aggregate.

## Using it

cairn treats **the row type and the domain entity as separate things**. What is
generated is the plumbing around the row type; the correspondence between the
two is written by the programmer.

### 1. Write the row type

```moonbit
#cairn.table(name="users", alias="u")
pub(all) struct User {
  #cairn.id
  id : Int
  name : String
  age : Int
  deleted_at : String?
} derive(Debug, Eq)
```

The annotated struct is **the flat shape of one row**. It has to be `pub(all)`:
callers build values to hand to `insert`, and a plain `pub` struct is read-only
to them.

`cols="..."` overrides the name of the column-handle struct (the default is
`<TypeName>Cols`).

### 2. Generate

```
moon run src/gen/cmd -- src/example/entities.mbt -o src/example/entities.g.mbt
```

You get `UserCols`, `User::cols()`, `User::all()`, `User::binding()`,
`User::table()`, `User::table_of()` and `User::primary_key_name()`. The output
is ordinary MoonBit source, so you can read it and diff it.

Downstream, a `pre-build` hook in `moon.pkg` calls a prebuilt `cairn-gen`.
**A hook that runs `moon run` inside the same module recurses forever**, so the
examples in this repository are generated explicitly.

### 3. When the row type and the domain entity do not line up

If the domain models its state transitions as a sum type, it will not be 1-1
with the table. The row has to leave `submitted_at` and `tracking` nullable,
while the domain type can make each state's fields unconditional.

```moonbit
#cairn.table(name="orders", alias="o", cols="OrderCols")
pub(all) struct OrderRow {
  #cairn.id
  id : Int
  items : Int
  status : String
  submitted_at : String?
  tracking : String?
}

pub(all) enum Order {
  Draft(id~ : Int, items~ : Int)
  Submitted(id~ : Int, items~ : Int, submitted_at~ : String)
  Shipped(id~ : Int, items~ : Int, submitted_at~ : String, tracking~ : String)
}
```

The mapping is written by hand. This is the only place the domain knowledge
actually lives.

```moonbit
pub fn Order::of_row(r : OrderRow) -> Order raise @sql.DecodeError {
  match (r.status, r.submitted_at, r.tracking) {
    ("draft", _, _) => Draft(id=r.id, items=r.items)
    ("submitted", Some(at), _) => Submitted(id=r.id, items=r.items, submitted_at=at)
    ("shipped", Some(at), Some(t)) =>
      Shipped(id=r.id, items=r.items, submitted_at=at, tracking=t)
    _ => raise @sql.Malformed("orders id=\{r.id}: illegal stored state")
  }
}

pub fn Order::to_row(self : Order) -> OrderRow { ... }
```

Then build a **table typed by the domain entity**.

```moonbit
pub fn orders() -> @sql.Table[OrderCols, Order] {
  OrderRow::table_of(Order::of_row, Order::to_row)
}
```

From there queries and DML both speak `Order`; `OrderRow` never crosses the
boundary. Only the reading direction may `raise`, deliberately: **the table can
hold combinations the domain type rejects**. The writing direction is total.

```mermaid
flowchart LR
    ROW["OrderRow<br/>generated row type"] -->|"of_row (may fail)"| DOM["Order<br/>hand-written domain type"]
    DOM -->|"to_row (total)"| ROW
    ROW -.-|"Selection::map / Binding::contramap"| SEAM["Table&lt;OrderCols, Order&gt;"]
```

When the row type and the domain type do agree, skip this step and use the
generated `User::table()` directly.

### 4. Queries

```moonbit
@sql.from(User::table())
|> @sql.Query::filter(u => u.age.gte(18) & u.deleted_at.is_none())
|> @sql.Query::map(u => @sql.sel(u.name))
|> @sql.Query::order_by(u => [u.name.asc()])
|> @sql.Query::limit(20)
```

```sql
SELECT u."name"
  FROM "users" AS u
 WHERE u."age" >= ? AND u."deleted_at" IS NULL
 ORDER BY u."name" ASC
 LIMIT ?
```

Filters are written against **the row's columns**, because that is what the
database has. What comes back is governed by the domain type.

### 5. DML

```moonbit
@sql.insert(User::table(), user)
@sql.insert_except(User::table(), user, omit=["id"])  // let the database assign the key
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

`update` and `delete` take the predicate as a **required argument**. As a step
in a chain it could be forgotten, and forgetting it rewrites the whole table;
to target every row you call `update_all` or `delete_all` and say so by name.

### 6. JOIN

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
```

`join` takes `Query[C1, A]` and `Table[C2, R2]` to `Query[(C1, C2), A]`. `Cols`
becomes a tuple, so from then on `.0` and `.1` reach each table's columns. A
third join nests further: `((C1, C2), C3)`.

Assembling one domain value out of several tables uses the same tools: write
the domain type into the `Selection[D]` that `Query::map(c => ...)` returns.

#### LEFT JOIN

The right-hand side of an outer join comes back as `Nullable[C2, R2]`, an
**abstract type with no exposed representation**. There is no route to a
`Column[T]` inside it. Exactly two ways in:

```moonbit
c.1.col(p => p.title)   // Column[String?]  -- when you want a column
c.1.row()               // Selection[Post?] -- when you want the row
```

`row()` is usually closer to what an outer join means. It is not saying that
each column might independently be NULL; it is saying **the row on the right
either exists or does not**, and inside `Some` every field keeps the type the
table declared.

```moonbit
@sql.from(User::table())
|> @sql.Query::left_join(Post::table(), (u, p) => u.id.eq_col(p.author_id))
|> @sql.Query::map(c => @sql.sel(c.0.name).zip(c.1.row()))
```

```
matched   -> ("alice", Some({ id: 7, title: "hello" }))
unmatched -> ("bob", None)
```

"No match" is detected as "every column on the right is NULL". That is always
right for a projection containing a column the database never leaves NULL, and
`Table::all` always includes one. For a hand-built projection of entirely
nullable columns, name the deciding column with `Selection::optional_on(key~)`.

## Execution

### Driver

All cairn asks of a real database is that it can run a statement plus an
ordered parameter list.

```moonbit
pub(open) trait Driver {
  query(Self, String, Array[SqlValue]) -> Array[Array[SqlValue]] raise DbError
  execute(Self, String, Array[SqlValue]) -> Int raise DbError
  dialect(Self) -> Dialect
  begin(Self) -> Unit raise DbError
  commit(Self) -> Unit raise DbError
  rollback(Self) -> Unit raise DbError
}
```

The driver is the connection. Pooling, if you want it, belongs outside.

### Running

```moonbit
query.run(db)     // Array[A]  -- every row
query.one(db)     // A         -- exactly one; NotFound at zero, TooManyRows above one
query.first(db)   // A?        -- the first row, if any
insert.run(db)    // Int       -- rows affected
update.run(db)    // Int
delete.run(db)    // Int
```

Over a table typed by a domain entity, what comes back is domain values. The
row type does not appear.

```moonbit
@sql.from(orders()).run(db)
// => [Shipped(id=1, items=3, submitted_at="2026-08-01", tracking="ZZ123"),
//     Draft(id=2, items=1)]
```

### Transactions

**There is no transaction monad.** MoonBit's error effect does that job, so the
body is an ordinary function that may `raise` part way through.

```moonbit
@sql.transaction(db, conn => {
  let removed = @sql.delete(DraftRow::table(), d => d.id.eq(2)).run(conn)
  let added = @sql.insert(SubmittedRow::table(), { id: 2, items: 1, submitted_at: at }).run(conn)
  (removed, added)
})
```

begin / commit / rollback are wrapped in a combinator rather than exposed
individually, so that a `raise` in the middle of the body cannot leave a
transaction open.

```mermaid
flowchart LR
    B["begin"] --> BODY["body(conn)"]
    BODY -->|"returns"| C["commit"] --> R1["result"]
    BODY -->|"raises"| RB["rollback"] --> R2["re-raise the same error"]
    B -->|"raises"| R3["propagate as is<br/>no rollback"]
```

- The body returning means COMMIT; the body raising means ROLLBACK and then
  **re-raising the same error**
- A rollback that itself fails **does not swallow the original error**, since
  the cause is the more useful of the two
- If `begin` fails there is nothing to undo, so no ROLLBACK is sent

All three are pinned by tests (`["BEGIN", "EXEC", "EXEC", "COMMIT"]`,
`["BEGIN", "EXEC", "ROLLBACK"]`, `[]`).

## The Repository pattern

cairn provides nothing for this. A repository is ordinary application code.

### The shape falls out of MoonBit's traits

A trait method cannot introduce type parameters of its own, so **a generic
`Repository[T, ID]` cannot be written**. What you get instead is an interface
per aggregate, in domain vocabulary — and `unassigned` says something a generic
`find_by(criteria)` cannot.

```moonbit
// Port: the domain's vocabulary. No dependency on cairn.
pub(open) trait TicketRepository {
  find(Self, Int) -> Ticket? raise
  save(Self, Ticket) -> Unit raise
  unassigned(Self) -> Array[Ticket] raise
}

// Adapter: generic over the driver, holding one as its connection.
struct SqlTickets[D] {
  db : D
}

pub impl[D : @sql.Driver] TicketRepository for SqlTickets[D] with find(self, id) {
  (ticket_query() |> @sql.Query::filter(c => c.0.0.id.eq(id))).first(self.db)
}
```

The `impl` needs `pub`. Without it, callers outside the package get
"no `impl` is defined".

### When the aggregate is spread over several tables

This is where a repository earns its keep. Take an aggregate split into phase
tables:

```
tickets(id, subject)
ticket_assignments(ticket_id -> tickets.id, assignee)
ticket_closures(ticket_id -> ticket_assignments.ticket_id, resolution)
```

`find` is a single statement with two outer joins.

```moonbit
@sql.from(TicketRow::table())
|> @sql.Query::left_join(AssignmentRow::table(), (t, a) => t.id.eq_col(a.ticket_id))
|> @sql.Query::left_join(ClosureRow::table(), (c, cl) => c.0.id.eq_col(cl.ticket_id))
|> @sql.Query::map(c => TicketRow::all(c.0.0).zip(c.0.1.row()).zip(c.1.row()).map(assemble))
```

**Which phase rows came back is the state.** No discriminator column exists.

| Rows returned | Aggregate rebuilt |
|---|---|
| base only | `Open(id=1, subject="printer on fire")` |
| base + assignment | `Assigned(..., assignee="dana")` |
| all three | `Closed(..., resolution="unplugged it")` |

A domain-meaningful query is the absence of a phase row.

```moonbit
|> @sql.Query::filter(c => c.0.1.col(a => a.ticket_id).is_none())
// -> WHERE ta."ticket_id" IS NULL
```

### `save` is where the ungenerable work lives

Phase rows are immutable facts, so saving is additive: read what is there and
insert only what is missing.

```moonbit
@sql.transaction(self.db, conn => {
  let before = self.find(id)
  if before is None { /* insert the base row */ }
  if ticket.assignee() is Some(a) && recorded_assignee is None { /* insert assignment */ }
  if ticket.resolution() is Some(r) && recorded_resolution is None { /* insert closure */ }
})
```

| Operation | Statements issued |
|---|---|
| save a new `Open` | `INSERT INTO "tickets" ("id", "subject")` |
| `Open` to `Assigned` | `INSERT INTO "ticket_assignments" ("ticket_id", "assignee")` |
| failure part way | `["BEGIN", "QUERY", "EXEC", "ROLLBACK"]` |

The base row is not rewritten. This is **where the aggregate's shape meets the
tables'**, and it is the part a generator cannot write.

### How it meets transactions

Since the driver is the connection, the `conn` in
`transaction(self.db, conn => ...)` is the same object as `self.db`. A
repository therefore **joins an enclosing transaction automatically**.

The flip side is that a repository cannot tell whether it is inside one. To put
several repositories into a single unit of work, rebind them to `conn` inside
the transaction.

```moonbit
@sql.transaction(db, conn => {
  let tickets = SqlTickets::new(conn)
  let users = SqlUsers::new(conn)
  ...
})
```

Constructing a repository is one struct, so this is cheap.

## Where it errs on the safe side

| Situation | Behaviour |
|---|---|
| INSERT with no rows | raises `EmptyInsert` |
| UPDATE with no assignment | raises `EmptyUpdate` |
| column count not matching value count | raises `ArityMismatch` |
| joining on a repeated alias (self-join) | raises `DuplicateAlias` |
| UPDATE / DELETE without a predicate | you must call `update_all` / `delete_all` |
| `one` finding zero or several rows | raises `NotFound` / `TooManyRows` |
| a transaction body failing | ROLLBACK, then the same error is re-raised |

## Not built yet

- **Aliasing and self-joins** — the `Column`s inside `Cols` bake in the alias,
  so `Table` would need to hold `cols` as `(String) -> Cols`
- **A security type parameter** — `Table[Sec, Cols, R]`, matching Acadia's
  `Table Unrestricted Food`. The `#cairn.table(security=...)` slot is reserved
- **Indexes, constraints, migrations** — unknown attribute names are ignored on
  purpose, so adding these later will not break an older generator
- **Aggregates** — `count_sel()` is a stub whose `read` ignores the row and
  returns 0

## Development

```
moon check      # type check
moon test       # tests
moon fmt        # format
moon info       # refresh .mbti
```

Package layout:

```
src/sql/        core library (expressions, projection, query, DML, emission)
src/gen/        code generator (attributes -> IR -> output)
src/gen/cmd/    CLI (cairn-gen)
src/example/    worked examples of entities and generated output
```

The generator parses MoonBit source with
[`moonbitlang/parser`](https://mooncakes.io/docs/moonbitlang/parser).
Attributes are read from the raw text in `Attribute.raw`, because `parsed` is
not populated for user-defined namespaces and `name()` drops the namespace.

The code blocks in this README are not type-checked. Checking them would mean
keeping the file as `.mbt.md` inside a package under `src/`; files outside the
module's `source = "src"` are not covered.
