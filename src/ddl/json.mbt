///|
/// An ordered JSON value.
///
/// `Json`'s object is a `Map`, whose iteration order is not something a file
/// committed to git should depend on. Snapshots are diffed by humans in code
/// review, so the writer keeps its own field order.
priv enum J {
  Str(String)
  Bool_(Bool)
  Null
  Arr(Array[J])
  Obj(Array[(String, J)])
}

///|
fn J::write(self : J, buf : StringBuilder, indent : Int) -> Unit {
  let pad = "  ".repeat(indent)
  let pad1 = "  ".repeat(indent + 1)
  match self {
    Null => buf.write_string("null")
    Bool_(b) => buf.write_string(if b { "true" } else { "false" })
    Str(s) => buf.write_string(quote(s))
    Arr(items) =>
      if items.is_empty() {
        buf.write_string("[]")
      } else {
        buf.write_string("[\n")
        for i, item in items {
          buf.write_string(pad1)
          item.write(buf, indent + 1)
          buf.write_string(if i == items.length() - 1 { "\n" } else { ",\n" })
        }
        buf.write_string(pad)
        buf.write_string("]")
      }
    Obj(entries) =>
      if entries.is_empty() {
        buf.write_string("{}")
      } else {
        buf.write_string("{\n")
        for i, kv in entries {
          let (k, v) = kv
          buf.write_string(pad1)
          buf.write_string(quote(k))
          buf.write_string(": ")
          v.write(buf, indent + 1)
          buf.write_string(if i == entries.length() - 1 { "\n" } else { ",\n" })
        }
        buf.write_string(pad)
        buf.write_string("}")
      }
  }
}

///|
/// Render a string as a JSON string literal.
fn quote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("\"")
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ =>
        if c.to_int() < 0x20 {
          buf.write_string("\\u\{pad4(c.to_int())}")
        } else {
          buf.write_char(c)
        }
    }
  }
  buf.write_string("\"")
  buf.to_string()
}

///|
/// Four-digit lower-case hex, for `\uXXXX` escapes.
fn pad4(n : Int) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let buf = StringBuilder::new()
  for shift in [12, 8, 4, 0] {
    let nibble = (n >> shift) & 0xf
    buf.write_char(digits[nibble])
  }
  buf.to_string()
}

///|
fn opt_str(v : String?) -> J {
  match v {
    Some(s) => Str(s)
    None => Null
  }
}

///|
/// Render a snapshot as the JSON that gets written to `meta/NNNN_snapshot.json`.
pub fn Snapshot::to_json_string(self : Snapshot) -> String {
  let buf = StringBuilder::new()
  J::Obj([
    ("version", Str(self.version)),
    ("dialect", Str(dialect_name(self.dialect))),
    ("tables", Arr(self.tables.map(table_json))),
  ]).write(buf, 0)
  buf.write_string("\n")
  buf.to_string()
}

///|
fn table_json(t : TableDef) -> J {
  Obj([
    ("name", Str(t.name)),
    ("columns", Arr(t.columns.map(column_json))),
    ("indexes", Arr(t.indexes.map(index_json))),
  ])
}

///|
fn column_json(c : ColumnDef) -> J {
  Obj([
    ("name", Str(c.name)),
    ("type", Str(c.ty)),
    ("not_null", Bool_(c.not_null)),
    ("primary_key", Bool_(c.primary_key)),
    ("autoincrement", Bool_(c.autoincrement)),
    ("unique", Bool_(c.unique)),
    ("default", opt_str(c.default_sql)),
    (
      "references",
      match c.references {
        None => Null
        Some(r) =>
          Obj([
            ("table", Str(r.table)),
            ("column", Str(r.column)),
            ("on_delete", opt_str(r.on_delete)),
            ("on_update", opt_str(r.on_update)),
          ])
      },
    ),
  ])
}

///|
fn index_json(i : IndexDef) -> J {
  Obj([
    ("name", Str(i.name)),
    ("columns", Arr(i.columns.map(c => J::Str(c)))),
    ("unique", Bool_(i.unique)),
  ])
}

///|
/// Read a snapshot back from its JSON.
///
/// Every failure is a `BadSnapshot` carrying where it went wrong: a snapshot
/// is machine-written but human-edited often enough that "invalid JSON" is not
/// a useful thing to say.
pub fn Snapshot::from_json_string(text : String) -> Snapshot raise DdlError {
  let json = @json.parse(text) catch {
    e => raise BadSnapshot(reason="not valid JSON: \{e}")
  }
  guard json is Object(root) else {
    raise BadSnapshot(reason="expected a JSON object at the top level")
  }
  let version = get_str(root, "version", "snapshot")
  guard version == SNAPSHOT_VERSION else {
    raise BadSnapshot(
      reason="snapshot format version \{version}, this aya writes \{SNAPSHOT_VERSION}",
    )
  }
  let dialect = dialect_of_name(get_str(root, "dialect", "snapshot"))
  let tables = []
  for t in get_arr(root, "tables", "snapshot") {
    tables.push(read_table(t))
  }
  { version, dialect, tables }
}

///|
fn read_table(json : Json) -> TableDef raise DdlError {
  guard json is Object(obj) else {
    raise BadSnapshot(reason="expected a table object")
  }
  let name = get_str(obj, "name", "table")
  let columns = []
  for c in get_arr(obj, "columns", "table \{name}") {
    columns.push(read_column(c, name))
  }
  let indexes = []
  for i in get_arr(obj, "indexes", "table \{name}") {
    indexes.push(read_index(i, name))
  }
  { name, columns, indexes }
}

///|
fn read_column(json : Json, table : String) -> ColumnDef raise DdlError {
  guard json is Object(obj) else {
    raise BadSnapshot(reason="expected a column object in table \{table}")
  }
  let name = get_str(obj, "name", "column in \{table}")
  let ctx = "column \{table}.\{name}"
  {
    name,
    ty: get_str(obj, "type", ctx),
    not_null: get_bool(obj, "not_null", ctx),
    primary_key: get_bool(obj, "primary_key", ctx),
    autoincrement: get_bool(obj, "autoincrement", ctx),
    unique: get_bool(obj, "unique", ctx),
    default_sql: get_opt_str(obj, "default", ctx),
    references: match obj.get("references") {
      None | Some(Null) => None
      Some(Object(r)) =>
        Some({
          table: get_str(r, "table", "\{ctx} references"),
          column: get_str(r, "column", "\{ctx} references"),
          on_delete: get_opt_str(r, "on_delete", "\{ctx} references"),
          on_update: get_opt_str(r, "on_update", "\{ctx} references"),
        })
      Some(_) =>
        raise BadSnapshot(
          reason="\{ctx}: `references` must be an object or null",
        )
    },
  }
}

///|
fn read_index(json : Json, table : String) -> IndexDef raise DdlError {
  guard json is Object(obj) else {
    raise BadSnapshot(reason="expected an index object in table \{table}")
  }
  let name = get_str(obj, "name", "index in \{table}")
  let columns = []
  for c in get_arr(obj, "columns", "index \{name}") {
    guard c is String(s) else {
      raise BadSnapshot(reason="index \{name}: column names must be strings")
    }
    columns.push(s)
  }
  { name, columns, unique: get_bool(obj, "unique", "index \{name}") }
}

///|
fn get_str(
  obj : Map[String, Json],
  key : String,
  ctx : String,
) -> String raise DdlError {
  match obj.get(key) {
    Some(String(s)) => s
    Some(_) => raise BadSnapshot(reason="\{ctx}: `\{key}` must be a string")
    None => raise BadSnapshot(reason="\{ctx}: missing `\{key}`")
  }
}

///|
fn get_opt_str(
  obj : Map[String, Json],
  key : String,
  ctx : String,
) -> String? raise DdlError {
  match obj.get(key) {
    None | Some(Null) => None
    Some(String(s)) => Some(s)
    Some(_) =>
      raise BadSnapshot(reason="\{ctx}: `\{key}` must be a string or null")
  }
}

///|
fn get_bool(
  obj : Map[String, Json],
  key : String,
  ctx : String,
) -> Bool raise DdlError {
  match obj.get(key) {
    Some(True) => true
    Some(False) => false
    Some(_) => raise BadSnapshot(reason="\{ctx}: `\{key}` must be a boolean")
    None => raise BadSnapshot(reason="\{ctx}: missing `\{key}`")
  }
}

///|
fn get_arr(
  obj : Map[String, Json],
  key : String,
  ctx : String,
) -> Array[Json] raise DdlError {
  match obj.get(key) {
    Some(Array(a)) => a
    Some(_) => raise BadSnapshot(reason="\{ctx}: `\{key}` must be an array")
    None => raise BadSnapshot(reason="\{ctx}: missing `\{key}`")
  }
}
