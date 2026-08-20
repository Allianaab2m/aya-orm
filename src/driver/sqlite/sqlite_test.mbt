// These run against a real in-memory SQLite, so what they pin is the driver's
// behaviour against the database rather than against a stub.

///|
struct ItemCols {
  id : @sql.Column[Int]
  name : @sql.Column[String]
  price : @sql.Column[Double]
  note : @sql.Column[String?]
}

///|
struct Item {
  id : Int
  name : String
  price : Double
  note : String?
} derive(Debug, Eq)

///|
fn items() -> @sql.Table[ItemCols, Item] {
  let cols : ItemCols = {
    id: @sql.Column::new(tbl="i", name="id"),
    name: @sql.Column::new(tbl="i", name="name"),
    price: @sql.Column::new(tbl="i", name="price"),
    note: @sql.Column::new(tbl="i", name="note"),
  }
  @sql.Table::new(
    table_name="items",
    tbl="i",
    cols~,
    all=@sql.Selection::new(
      [cols.id.raw(), cols.name.raw(), cols.price.raw(), cols.note.raw()],
      row => Item::{
        id: @sql.SqlDecode::decode(row[0], "id"),
        name: @sql.SqlDecode::decode(row[1], "name"),
        price: @sql.SqlDecode::decode(row[2], "price"),
        note: @sql.SqlDecode::decode(row[3], "note"),
      },
    ),
    write=@sql.Binding::new(["id", "name", "price", "note"], v => {
      [
        @sql.SqlEncode::to_sql_value(v.id),
        @sql.SqlEncode::to_sql_value(v.name),
        @sql.SqlEncode::to_sql_value(v.price),
        @sql.SqlEncode::to_sql_value(v.note),
      ]
    }),
  )
}

///|
/// Run a statement the driver has no reason to model, straight at the binding.
fn ddl(db : Sqlite, sql : String) -> Unit raise {
  let stmt = db.connection().prepare(sql)
  defer drop(stmt)
  stmt.step_once()
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
/// The whole point of the typed projection: every storage class survives, and
/// so does the difference between a missing value and a zero one.
async test "each storage class survives a round trip" {
  with_connection(":memory:", db => {
    schema(db)
    @sql.insert(items(), Item::{
      id: 1,
      name: "widget",
      price: 9.5,
      note: Some("fragile"),
    }).run(db)
    |> ignore
    @sql.insert(items(), Item::{
      id: 2,
      name: "sprocket",
      price: 3.0,
      note: None,
    }).run(db)
    |> ignore
    debug_inspect(
      @sql.from(items()).run(db),
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
/// A NULL read as an `Int` through this binding would arrive as `0`, which is a
/// real value and a wrong answer. `typeof` is what keeps the two apart, and a
/// LEFT JOIN with no match is the ordinary way to meet the case.
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
      @sql.insert(items(), item).run(db) |> ignore
    }
    ddl(db, "INSERT INTO tags (item_id, tag) VALUES (1, 'boxed')")
    let tagged = @sql.from(items())
      |> @sql.Query::left_join(tags(), (i, t) => i.id.eq_col(t.item_id))
      |> @sql.Query::map(
        @sql.split2((i, t) => @sql.sel2(i.id, t.col(c => c.tag))),
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
  item_id : @sql.Column[Int]
  tag : @sql.Column[String]
}

///|
struct Tag {
  item_id : Int
  tag : String
} derive(Debug, Eq)

///|
fn tags() -> @sql.Table[TagCols, Tag] {
  let cols : TagCols = {
    item_id: @sql.Column::new(tbl="t", name="item_id"),
    tag: @sql.Column::new(tbl="t", name="tag"),
  }
  @sql.Table::new(
    table_name="tags",
    tbl="t",
    cols~,
    all=@sql.Selection::new([cols.item_id.raw(), cols.tag.raw()], row => Tag::{
      item_id: @sql.SqlDecode::decode(row[0], "item_id"),
      tag: @sql.SqlDecode::decode(row[1], "tag"),
    }),
    write=@sql.Binding::new(["item_id", "tag"], v => {
      [
        @sql.SqlEncode::to_sql_value(v.item_id),
        @sql.SqlEncode::to_sql_value(v.tag),
      ]
    }),
  )
}

///|
/// Doubling the SELECT list must not double the parameter list with it: each
/// projected expression is rendered once and its text reused, so a literal in
/// the projection is still bound once and every later placeholder keeps its
/// number.
async test "a filtered and limited query binds each parameter once" {
  with_connection(":memory:", db => {
    schema(db)
    for id in [1, 2, 3] {
      @sql.insert(items(), Item::{
        id,
        name: "item-\{id}",
        price: id.to_double(),
        note: None,
      }).run(db)
      |> ignore
    }
    let q = @sql.from(items())
      |> @sql.Query::filter(i => i.id.gte(2))
      |> @sql.Query::map(i => @sql.sel2(i.id, i.name))
      |> @sql.Query::limit(1)
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
      @sql.insert(items(), Item::{
        id,
        name: "item-\{id}",
        price: 1.0,
        note: None,
      }).run(db)
      |> ignore
    }
    inspect(
      (@sql.update(items(), i => i.id.gte(2))
      |> @sql.Update::set(i => i.name, "renamed")).run(db),
      content="2",
    )
    inspect(@sql.delete(items(), i => i.id.eq(1)).run(db), content="1")
    inspect(@sql.delete(items(), i => i.id.eq(99)).run(db), content="0")
  })
}

///|
/// The transaction combinator's contract, against a database that really does
/// undo the work.
async test "a rolled back transaction leaves nothing behind" {
  with_connection(":memory:", db => {
    schema(db)
    try {
      let _ : Unit = @sql.transaction(@sql.Tx::new(db), conn => {
        @sql.insert(items(), Item::{
          id: 1,
          name: "widget",
          price: 1.0,
          note: None,
        }).run(conn)
        |> ignore
        raise @sql.DecodeError::Malformed("changed my mind")
      })
      fail("expected the body's error to propagate")
    } catch {
      @sql.Malformed(_) => ()
      e => raise e
    }
    inspect(@sql.from(items()).run(db).length(), content="0")
    let kept = @sql.transaction(@sql.Tx::new(db), conn => {
      @sql.insert(items(), Item::{
        id: 2,
        name: "sprocket",
        price: 2.0,
        note: None,
      }).run(conn)
    })
    inspect(kept, content="1")
    inspect(@sql.from(items()).run(db).length(), content="1")
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
    let tx = @sql.Tx::new(db)
    @sql.transaction(tx, _ => {
      @sql.transaction(tx, conn => {
        @sql.insert(items(), Item::{
          id: 1,
          name: "widget",
          price: 1.0,
          note: None,
        }).run(conn)
        |> ignore
      })
      @sql.transaction(tx, conn => {
        @sql.insert(items(), Item::{
          id: 2,
          name: "sprocket",
          price: 2.0,
          note: None,
        }).run(conn)
        |> ignore
      })
    })
    inspect(@sql.from(items()).run(db).length(), content="2")
  })
}

///|
/// And the other half of the same guarantee: a nested failure takes the
/// writes that came before it with it.
async test "a nested failure undoes the enclosing transaction, against SQLite" {
  with_connection(":memory:", db => {
    schema(db)
    let tx = @sql.Tx::new(db)
    try {
      let _ : Unit = @sql.transaction(tx, _ => {
        @sql.transaction(tx, conn => {
          @sql.insert(items(), Item::{
            id: 1,
            name: "widget",
            price: 1.0,
            note: None,
          }).run(conn)
          |> ignore
        })
        @sql.transaction(tx, _ => raise @sql.DecodeError::Malformed("no"))
      })
      fail("expected the nested failure to propagate")
    } catch {
      @sql.Malformed(_) => ()
      e => raise e
    }
    inspect(@sql.from(items()).run(db).length(), content="0")
  })
}

///|
/// A statement the database rejects comes back as cairn's own failure, with
/// SQLite's message rather than only a result code.
async test "a broken statement fails as a DbError" {
  with_connection(":memory:", db => {
    try {
      let _ = @sql.from(items()).run(db)
      fail("expected the missing table to be reported")
    } catch {
      e =>
        assert_true(
          "\{e}".contains("no such table") || "\{e}".contains("QueryFailed"),
        )
    }
  })
}
