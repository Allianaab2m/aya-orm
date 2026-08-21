// These run against a real in-memory SQLite, so what they pin is the driver's
// behaviour against the database rather than against a stub.

///|
struct ItemCols {
  id : @aya.Column[Int]
  name : @aya.Column[String]
  price : @aya.Column[Double]
  note : @aya.Column[String?]
}

///|
struct Item {
  id : Int
  name : String
  price : Double
  note : String?
} derive(Debug, Eq)

///|
fn items() -> @aya.Table[ItemCols, Item] {
  let cols : ItemCols = {
    id: @aya.Column::new(tbl="i", name="id"),
    name: @aya.Column::new(tbl="i", name="name"),
    price: @aya.Column::new(tbl="i", name="price"),
    note: @aya.Column::new(tbl="i", name="note"),
  }
  @aya.Table::new(
    table_name="items",
    tbl="i",
    cols~,
    all=@aya.Selection::new(
      [cols.id.raw(), cols.name.raw(), cols.price.raw(), cols.note.raw()],
      row => Item::{
        id: @aya.SqlDecode::decode(row[0], "id"),
        name: @aya.SqlDecode::decode(row[1], "name"),
        price: @aya.SqlDecode::decode(row[2], "price"),
        note: @aya.SqlDecode::decode(row[3], "note"),
      },
    ),
    write=@aya.Binding::new(["id", "name", "price", "note"], v => {
      [
        @aya.SqlEncode::to_sql_value(v.id),
        @aya.SqlEncode::to_sql_value(v.name),
        @aya.SqlEncode::to_sql_value(v.price),
        @aya.SqlEncode::to_sql_value(v.note),
      ]
    }),
  )
}

///|
/// Run a statement the driver has no reason to model, straight at the binding.
fn ddl(db : Sqlite, sql : String) -> Unit raise {
  let stmt = db.connection().prepare(sql)
  defer drop(stmt)
  // DDL produces no rows, so the first step is also the last one.
  stmt.step() |> ignore
}

///|
fn drop(stmt : @sqlite3.Statement) -> Unit {
  stmt.finalize() catch {
    _ => ()
  }
}

///|
fn schema(db : Sqlite) -> Unit raise {
  ddl(
    db,
    (
      #|CREATE TABLE items (
      #|  id INTEGER PRIMARY KEY,
      #|  name TEXT NOT NULL,
      #|  price REAL NOT NULL,
      #|  note TEXT,
      #|  blob BLOB
      #|)
    ),
  )
}

///|
/// Every storage class survives the round trip, and so does the difference
/// between a missing value and a zero one.
async test "each storage class survives a round trip" {
  with_connection(":memory:", db => {
    schema(db)
    @aya.insert(items(), Item::{
      id: 1,
      name: "widget",
      price: 9.5,
      note: Some("fragile"),
    }).run(db)
    |> ignore
    @aya.insert(items(), Item::{
      id: 2,
      name: "sprocket",
      price: 3.0,
      note: None,
    }).run(db)
    |> ignore
    debug_inspect(
      @aya.from(items()).run(db),
      content=(
        #|[
        #|  { id: 1, name: "widget", price: 9.5, note: Some("fragile") },
        #|  { id: 2, name: "sprocket", price: 3, note: None },
        #|]
      ),
    )
  })
}

///|
/// A NULL read as an `Int64` would arrive as `0`, which is a real value and a
/// wrong answer. Reading the column as a `@sqlite3.Value` is what keeps the two
/// apart, and a LEFT JOIN with no match is the ordinary way to meet the case.
async test "a missing outer-joined row decodes as None, not as zero" {
  with_connection(":memory:", db => {
    schema(db)
    ddl(
      db, "CREATE TABLE tags (item_id INTEGER PRIMARY KEY, tag TEXT NOT NULL)",
    )
    for
      item in [
        Item::{ id: 1, name: "widget", price: 9.5, note: None },
        Item::{ id: 2, name: "sprocket", price: 3.0, note: None },
      ] {
      @aya.insert(items(), item).run(db) |> ignore
    }
    ddl(db, "INSERT INTO tags (item_id, tag) VALUES (1, 'boxed')")
    let tagged = @aya.from(items())
      |> @aya.Query::left_join(tags(), (i, t) => i.id.eq_col(t.item_id))
      |> @aya.Query::map(
        @aya.split2((i, t) => @aya.sel2(i.id, t.col(c => c.tag))),
      )
    debug_inspect(
      tagged.run(db),
      content=(
        #|[(1, Some("boxed")), (2, None)]
      ),
    )
  })
}

///|
struct TagCols {
  item_id : @aya.Column[Int]
  tag : @aya.Column[String]
}

///|
struct Tag {
  item_id : Int
  tag : String
} derive(Debug, Eq)

///|
fn tags() -> @aya.Table[TagCols, Tag] {
  let cols : TagCols = {
    item_id: @aya.Column::new(tbl="t", name="item_id"),
    tag: @aya.Column::new(tbl="t", name="tag"),
  }
  @aya.Table::new(
    table_name="tags",
    tbl="t",
    cols~,
    all=@aya.Selection::new([cols.item_id.raw(), cols.tag.raw()], row => Tag::{
      item_id: @aya.SqlDecode::decode(row[0], "item_id"),
      tag: @aya.SqlDecode::decode(row[1], "tag"),
    }),
    write=@aya.Binding::new(["item_id", "tag"], v => {
      [
        @aya.SqlEncode::to_sql_value(v.item_id),
        @aya.SqlEncode::to_sql_value(v.tag),
      ]
    }),
  )
}

///|
/// Placeholders are numbered across the whole statement, so a query that both
/// filters and limits has to bind them in the order they were written.
async test "a filtered and limited query binds each parameter once" {
  with_connection(":memory:", db => {
    schema(db)
    for id in [1, 2, 3] {
      @aya.insert(items(), Item::{
        id,
        name: "item-\{id}",
        price: id.to_double(),
        note: None,
      }).run(db)
      |> ignore
    }
    let q = @aya.from(items())
      |> @aya.Query::filter(i => i.id.gte(2))
      |> @aya.Query::map(i => @aya.sel2(i.id, i.name))
      |> @aya.Query::limit(1)
    debug_inspect(
      q.run(db),
      content=(
        #|[(2, "item-2")]
      ),
    )
  })
}

///|
/// SQLite's own `changes()` is asked on the same connection, so the count is
/// the one the statement actually produced rather than an assumption.
async test "writes report how many rows they touched" {
  with_connection(":memory:", db => {
    schema(db)
    for id in [1, 2, 3] {
      @aya.insert(items(), Item::{
        id,
        name: "item-\{id}",
        price: 1.0,
        note: None,
      }).run(db)
      |> ignore
    }
    inspect(
      (@aya.update(items(), i => i.id.gte(2))
      |> @aya.Update::set(i => i.name, "renamed")).run(db),
      content="2",
    )
    inspect(@aya.delete(items(), i => i.id.eq(1)).run(db), content="1")
    inspect(@aya.delete(items(), i => i.id.eq(99)).run(db), content="0")
  })
}

///|
/// The transaction combinator's contract, against a database that really does
/// undo the work.
async test "a rolled back transaction leaves nothing behind" {
  with_connection(":memory:", db => {
    schema(db)
    try {
      let _ : Unit = @aya.transaction(@aya.Tx::new(db), conn => {
        @aya.insert(items(), Item::{
          id: 1,
          name: "widget",
          price: 1.0,
          note: None,
        }).run(conn)
        |> ignore
        raise @aya.DecodeError::Malformed("changed my mind")
      })
      fail("expected the body's error to propagate")
    } catch {
      @aya.Malformed(_) => ()
      e => raise e
    }
    inspect(@aya.from(items()).run(db).length(), content="0")
    let kept = @aya.transaction(@aya.Tx::new(db), conn => {
      @aya.insert(items(), Item::{
        id: 2,
        name: "sprocket",
        price: 2.0,
        note: None,
      }).run(conn)
    })
    inspect(kept, content="1")
    inspect(@aya.from(items()).run(db).length(), content="1")
  })
}

///|
/// Nesting against a database that really does refuse a second `BEGIN`.
///
/// SQLite answers `cannot start a transaction within a transaction`, so this
/// is the test that would fail if an inner scope ever sent one — and the one
/// that shows both writes were committed by the single outer `COMMIT`.
async test "nested transactions commit once, against SQLite" {
  with_connection(":memory:", db => {
    schema(db)
    let tx = @aya.Tx::new(db)
    @aya.transaction(tx, _ => {
      @aya.transaction(tx, conn => {
        @aya.insert(items(), Item::{
          id: 1,
          name: "widget",
          price: 1.0,
          note: None,
        }).run(conn)
        |> ignore
      })
      @aya.transaction(tx, conn => {
        @aya.insert(items(), Item::{
          id: 2,
          name: "sprocket",
          price: 2.0,
          note: None,
        }).run(conn)
        |> ignore
      })
    })
    inspect(@aya.from(items()).run(db).length(), content="2")
  })
}

///|
/// And the other half of the same guarantee: a nested failure takes the
/// writes that came before it with it.
async test "a nested failure undoes the enclosing transaction, against SQLite" {
  with_connection(":memory:", db => {
    schema(db)
    let tx = @aya.Tx::new(db)
    try {
      let _ : Unit = @aya.transaction(tx, _ => {
        @aya.transaction(tx, conn => {
          @aya.insert(items(), Item::{
            id: 1,
            name: "widget",
            price: 1.0,
            note: None,
          }).run(conn)
          |> ignore
        })
        @aya.transaction(tx, _ => raise @aya.DecodeError::Malformed("no"))
      })
      fail("expected the nested failure to propagate")
    } catch {
      @aya.Malformed(_) => ()
      e => raise e
    }
    inspect(@aya.from(items()).run(db).length(), content="0")
  })
}

///|
/// A statement the database rejects comes back as aya's own failure, carrying
/// what SQLite said about it.
///
/// The binding captures `sqlite3_errmsg` where the call failed, so the message
/// is always there — there is no window in which asking the connection after
/// the fact comes back empty.
async test "a broken statement fails as a DbError" {
  with_connection(":memory:", db => {
    try {
      let _ = @aya.from(items()).run(db)
      fail("expected the missing table to be reported")
    } catch {
      // Matched apart rather than stringified: `"\{e}"` renders only the
      // constructor's path, so the message has to be read off the payload.
      @aya.QueryFailed(sql~, message~) => {
        assert_true(sql.contains("FROM \"items\""))
        assert_true(message.contains("no such table: items"))
        assert_true(message.contains("code=Error"))
      }
      e => raise e
    }
  })
}
